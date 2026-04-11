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

// MARK: - View Model

@Observable
final class NotificationSettingsViewModel {
    var directMessagesMode: DefaultNotificationMode = .allMessages
    var groupRoomsMode: DefaultNotificationMode = .mentionsAndKeywordsOnly
    var callsEnabled = true
    var invitesEnabled = true
    var roomMentionsEnabled = true
    var userMentionsEnabled = true
    var isLoading = true
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
        } catch {
            errorReporter?.report(.notificationSettingsFailed(error.localizedDescription))
        }
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
}

// MARK: - Notifications Tab

/// The Notifications tab of the Settings window, providing controls for default
/// notification modes for direct messages and group rooms, plus toggles for
/// invitations, @room mentions, and @user mentions.
struct SettingsNotificationsTab: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @State private var viewModel = NotificationSettingsViewModel()
    @AppStorage("notifications.sessionEnabled") private var sessionEnabled = true

    var body: some View {
        Form {
            if viewModel.isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            } else {
                Section {
                    Toggle("Enable on this device", isOn: $sessionEnabled)
                }

                Section {
                    Picker("Direct Messages", selection: directMessagesBinding) {
                        ForEach(DefaultNotificationMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                } header: {
                    Text("Direct Messages")
                    Text("Default notification level for one-to-one conversations.")
                }

                Section {
                    Picker("Group Rooms", selection: groupRoomsBinding) {
                        ForEach(DefaultNotificationMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                } header: {
                    Text("Group Rooms")
                    Text("Default notification level for rooms with more than two members.")
                }

                Section("Other Notifications") {
                    Toggle("Invitations", isOn: invitesBinding)
                    Toggle("@room Mentions", isOn: roomMentionsBinding)
                    Toggle("@user Mentions", isOn: userMentionsBinding)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            viewModel.errorReporter = errorReporter
            await viewModel.load(service: matrixService)
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

#Preview {
    TabView {
        SettingsNotificationsTab()
            .tabItem { Label("Notifications", systemImage: "bell") }
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 480)
}
