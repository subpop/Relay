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
import UserNotifications

// MARK: - View Model

@Observable
final class NotificationSettingsViewModel {
    var directMessagesMode: DefaultNotificationMode = .allMessages
    var groupRoomsMode: DefaultNotificationMode = .mentionsAndKeywordsOnly
    var callsEnabled = true
    var invitesEnabled = true
    var roomMentionsEnabled = true
    var userMentionsEnabled = true
    var keywords: [String] = []
    var isLoading = true
    var hasConfigurationMismatch = false
    var isFixingMismatch = false
    var systemNotificationsGranted: Bool?
    var roomsWithCustomSettings: [String] = []
    var errorReporter: ErrorReporter?

    private var matrixService: (any MatrixServiceProtocol)?

    @MainActor
    func load(service: any MatrixServiceProtocol) async {
        matrixService = service
        do {
            directMessagesMode = try await service.getDefaultNotificationMode(isOneToOne: true)
            groupRoomsMode = try await service.getDefaultNotificationMode(isOneToOne: false)
            callsEnabled = try await service.isCallNotificationEnabled()
            invitesEnabled = try await service.isInviteNotificationEnabled()
            roomMentionsEnabled = try await service.isRoomMentionEnabled()
            userMentionsEnabled = try await service.isUserMentionEnabled()
            keywords = try await service.getNotificationKeywords()
            hasConfigurationMismatch = try await !service.hasConsistentNotificationSettings()
            roomsWithCustomSettings = try await service.roomsWithCustomNotificationSettings()
        } catch {
            errorReporter?.report(.notificationSettingsFailed(error.localizedDescription))
        }

        // Check system notification authorization
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        systemNotificationsGranted = settings.authorizationStatus == .authorized

        isLoading = false
    }

    @MainActor
    func update(_ block: @escaping (any MatrixServiceProtocol) async throws -> Void) {
        guard let matrixService else { return }
        Task {
            do {
                try await block(matrixService)
            } catch {
                errorReporter?.report(.notificationSettingsFailed(error.localizedDescription))
            }
        }
    }

    @MainActor
    func fixConfigurationMismatch() {
        guard !isFixingMismatch else { return }
        isFixingMismatch = true
        Task {
            do {
                try await matrixService?.fixInconsistentNotificationSettings()
                hasConfigurationMismatch = false
                // Reload modes after fix
                if let service = matrixService {
                    directMessagesMode = try await service.getDefaultNotificationMode(isOneToOne: true)
                    groupRoomsMode = try await service.getDefaultNotificationMode(isOneToOne: false)
                }
            } catch {
                errorReporter?.report(.notificationSettingsFailed(error.localizedDescription))
            }
            isFixingMismatch = false
        }
    }

    @MainActor
    func addKeyword(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !keywords.contains(trimmed) else { return }
        keywords.append(trimmed)
        update { try await $0.addNotificationKeyword(trimmed) }
    }

    @MainActor
    func removeKeyword(_ keyword: String) {
        keywords.removeAll { $0 == keyword }
        update { try await $0.removeNotificationKeyword(keyword) }
    }
}

// MARK: - Notifications Tab

/// The Notifications tab of the Settings window, providing controls for default
/// notification modes, mention and keyword settings, and other notification toggles.
struct SettingsNotificationsTab: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @State private var viewModel = NotificationSettingsViewModel()

    var body: some View {
        Form {
            if viewModel.isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            } else {
                if viewModel.hasConfigurationMismatch {
                    configurationMismatchSection
                }
                if viewModel.systemNotificationsGranted == false {
                    systemPermissionSection
                }
                defaultLevelsSection
                mentionsSection
                otherSection
                if !viewModel.roomsWithCustomSettings.isEmpty {
                    customRoomsSection
                }
            }
        }
        .formStyle(.grouped)
        .task {
            viewModel.errorReporter = errorReporter
            await viewModel.load(service: matrixService)
        }
    }

    // MARK: - Configuration Mismatch

    private var configurationMismatchSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Inconsistent Notification Settings", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fontWeight(.medium)
                Text(
                    "Your notification settings for encrypted and unencrypted rooms are "
                    + "out of sync, likely from an older Matrix client. This can cause "
                    + "unexpected notification behavior."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Button("Fix Settings") {
                    viewModel.fixConfigurationMismatch()
                }
                .disabled(viewModel.isFixingMismatch)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - System Permission Warning

    private var systemPermissionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("System Notifications Disabled", systemImage: "bell.slash.fill")
                    .foregroundStyle(.red)
                    .fontWeight(.medium)
                Text(
                    "Relay does not have permission to show notifications. "
                    + "Enable notifications in System Settings to receive alerts."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Button("Open System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Default Notification Levels

    private var defaultLevelsSection: some View {
        Section {
            Picker("Direct Messages", selection: directMessagesBinding) {
                ForEach(DefaultNotificationMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Picker("Group Rooms", selection: groupRoomsBinding) {
                ForEach(DefaultNotificationMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        } header: {
            Text("Default Notification Level")
            Text("Choose the default notification level for new conversations.")
        }
    }

    // MARK: - Mentions & Keywords

    private var mentionsSection: some View {
        Section {
            Toggle("When I'm mentioned", isOn: userMentionsBinding)
            Toggle("When the whole room is notified", isOn: roomMentionsBinding)

            KeywordsEditor(
                keywords: viewModel.keywords,
                onAdd: { viewModel.addKeyword($0) },
                onRemove: { viewModel.removeKeyword($0) }
            )
        } header: {
            Text("Mentions & Keywords")
            Text("Get notified and highlight messages containing your name, a mention, or a keyword you specify.")
        }
    }

    // MARK: - Other

    private var otherSection: some View {
        Section("Other") {
            Toggle("Invitations", isOn: invitesBinding)
            Toggle("Calls", isOn: callsBinding)
        }
    }

    // MARK: - Rooms with Custom Settings

    private var customRoomsSection: some View {
        Section {
            ForEach(viewModel.roomsWithCustomSettings, id: \.self) { roomId in
                if let room = matrixService.rooms.first(where: { $0.id == roomId }) {
                    HStack(spacing: 10) {
                        AvatarView(name: room.name, mxcURL: room.avatarURL, size: 24)
                        Text(room.name)
                            .lineLimit(1)
                        Spacer()
                        if let mode = room.notificationMode {
                            Text(mode.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Per-Room Overrides")
            Text("These rooms have notification settings that differ from the defaults above.")
        }
    }

    // MARK: - Bindings

    private var directMessagesBinding: Binding<DefaultNotificationMode> {
        Binding(
            get: { viewModel.directMessagesMode },
            set: { newValue in
                viewModel.directMessagesMode = newValue
                viewModel.update { try await $0.setDefaultNotificationMode(isOneToOne: true, mode: newValue) }
            }
        )
    }

    private var groupRoomsBinding: Binding<DefaultNotificationMode> {
        Binding(
            get: { viewModel.groupRoomsMode },
            set: { newValue in
                viewModel.groupRoomsMode = newValue
                viewModel.update { try await $0.setDefaultNotificationMode(isOneToOne: false, mode: newValue) }
            }
        )
    }

    private var callsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.callsEnabled },
            set: { newValue in
                viewModel.callsEnabled = newValue
                viewModel.update { try await $0.setCallNotificationEnabled(newValue) }
            }
        )
    }

    private var invitesBinding: Binding<Bool> {
        Binding(
            get: { viewModel.invitesEnabled },
            set: { newValue in
                viewModel.invitesEnabled = newValue
                viewModel.update { try await $0.setInviteNotificationEnabled(newValue) }
            }
        )
    }

    private var roomMentionsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.roomMentionsEnabled },
            set: { newValue in
                viewModel.roomMentionsEnabled = newValue
                viewModel.update { try await $0.setRoomMentionEnabled(newValue) }
            }
        )
    }

    private var userMentionsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.userMentionsEnabled },
            set: { newValue in
                viewModel.userMentionsEnabled = newValue
                viewModel.update { try await $0.setUserMentionEnabled(newValue) }
            }
        )
    }
}

// MARK: - Keywords Editor

/// An inline keyword list with an add field. Keywords appear as removable tags
/// below the text field.
private struct KeywordsEditor: View {
    let keywords: [String]
    var onAdd: (String) -> Void
    var onRemove: (String) -> Void

    @State private var newKeyword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add keyword…", text: $newKeyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addKeyword() }

                Button("Add", action: addKeyword)
                    .disabled(newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !keywords.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(keywords, id: \.self) { keyword in
                        KeywordTag(keyword: keyword) {
                            onRemove(keyword)
                        }
                    }
                }
            }
        }
    }

    private func addKeyword() {
        let trimmed = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        newKeyword = ""
    }
}

// MARK: - Keyword Tag

/// A small capsule displaying a keyword with a remove button.
private struct KeywordTag: View {
    let keyword: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(keyword)
                .font(.callout)

            Button("Remove keyword", systemImage: "xmark", action: onRemove)
                .font(.caption2)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
}

#Preview {
    TabView {
        SettingsNotificationsTab()
            .tabItem { Label("Notifications", systemImage: "bell") }
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 480)
}
#Preview("Per-Room Overrides") {
    let service = PreviewMatrixService()
    // Set custom notification modes on some rooms
    service.rooms[0].notificationMode = .mentionsAndKeywordsOnly // Design Team
    service.rooms[2].notificationMode = .mute                   // Matrix HQ
    service.customNotificationRoomIds = [
        "!design:matrix.org",
        "!hq:matrix.org",
    ]

    return TabView {
        SettingsNotificationsTab()
            .tabItem { Label("Notifications", systemImage: "bell") }
    }
    .environment(\.matrixService, service)
    .frame(width: 480)
}

