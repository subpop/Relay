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

// MARK: - Settings View

/// The settings window, organized into tabs for general profile, notifications, safety/privacy,
/// session management, and encryption status.
struct SettingsView: View {
    @Environment(\.matrixService) private var matrixService

    var body: some View {
        Group {
            if matrixService.userId() != nil {
                TabView {
                    AccountSettingsTab()
                        .tabItem { Label("Account", systemImage: "person.crop.circle") }
                    BehaviorSettingsTab()
                        .tabItem { Label("Behavior", systemImage: "gearshape") }
                    NotificationSettingsTab()
                        .tabItem { Label("Notifications", systemImage: "bell") }
                    SessionsSettingsTab()
                        .tabItem { Label("Sessions", systemImage: "desktopcomputer") }
                    EncryptionSettingsTab()
                        .tabItem { Label("Encryption", systemImage: "lock.fill") }
                }
            } else {
                ContentUnavailableView(
                    "Not Signed In",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Sign in to access settings.")
                )
            }
        }
        .frame(width: 480)
    }
}

// MARK: - Account Tab

private struct AccountSettingsTab: View {
    @Environment(\.matrixService) private var matrixService

    @State private var displayName = ""
    @State private var savedDisplayName = ""
    @State private var avatarURL: String?
    @State private var showLogoutConfirmation = false
    @State private var displayNameSaveTask: Task<Void, Never>?

    private var userId: String? { matrixService.userId() }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AvatarView(
                        name: displayName.isEmpty ? (userId ?? "?") : displayName,
                        mxcURL: avatarURL,
                        size: 64
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName.isEmpty ? "Not set" : displayName)
                            .font(.title3)
                            .fontWeight(.medium)
                        if let userId {
                            Text(userId)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, 4)

                Button("Log Out…", role: .destructive) {
                    showLogoutConfirmation = true
                }
                .controlSize(.small)
            }

            Section("Profile") {
                TextField("Display Name", text: $displayName)

                if let userId {
                    LabeledContent("User ID") {
                        HStack(spacing: 6) {
                            Text(userId)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(userId, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.borderless)
                            .help("Copy User ID")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            let name = await matrixService.userDisplayName() ?? ""
            displayName = name
            savedDisplayName = name
            avatarURL = await matrixService.userAvatarURL()
        }
        .onChange(of: displayName) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != savedDisplayName else { return }
            displayNameSaveTask?.cancel()
            displayNameSaveTask = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                try? await matrixService.setDisplayName(trimmed)
                savedDisplayName = trimmed
            }
        }
        .alert("Log Out", isPresented: $showLogoutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Log Out", role: .destructive) {
                Task { await matrixService.logout() }
            }
        } message: {
            Text("Are you sure you want to log out? You will need to sign in again.")
        }
    }
}

// MARK: - Behavior Tab

private struct BehaviorSettingsTab: View {
    @AppStorage("safety.sendReadReceipts") private var sendReadReceipts = true
    @AppStorage("safety.sendTypingNotifications") private var sendTypingNotifications = true
    @AppStorage("safety.mediaPreviewMode") private var mediaPreviewMode = MediaPreviewMode.privateOnly
    @AppStorage("behavior.showURLPreviews") private var showURLPreviews = true
    @AppStorage("behavior.alwaysLoadNewest") private var alwaysLoadNewest = true

    var body: some View {
        Form {
            Section("Privacy") {
                Toggle("Send Read Receipts", isOn: $sendReadReceipts)
                Toggle("Send Typing Notifications", isOn: $sendTypingNotifications)
            }

            Section {
                Toggle("Always Load Newest Messages", isOn: $alwaysLoadNewest)
            } header: {
                Text("Timeline")
                Text("When disabled, rooms open at your last read position so you can catch up on missed messages.")
            }

            Section {
                Toggle("Show URL Previews", isOn: $showURLPreviews)

                Picker("Show Media Previews In", selection: $mediaPreviewMode) {
                    ForEach(MediaPreviewMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Media")
                Text("Hidden previews can always be revealed by clicking on the media.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notification Settings

@Observable
private final class NotificationSettingsViewModel {
    var directMessagesMode: DefaultNotificationMode = .allMessages
    var groupRoomsMode: DefaultNotificationMode = .mentionsAndKeywordsOnly
    var callsEnabled = true
    var invitesEnabled = true
    var roomMentionsEnabled = true
    var userMentionsEnabled = true
    var isLoading = true
    var errorMessage: String?

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
            errorMessage = error.localizedDescription
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
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct NotificationSettingsTab: View {
    @Environment(\.matrixService) private var matrixService
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
        .task { await viewModel.load(service: matrixService) }
        .alert("Notification Settings Error", isPresented: showErrorBinding) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
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

    private var showErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

// MARK: - Safety Settings

private enum MediaPreviewMode: String, CaseIterable {
    case allRooms
    case privateOnly

    var label: String {
        switch self {
        case .allRooms: "All rooms"
        case .privateOnly: "Private rooms only"
        }
    }
}

// MARK: - Sessions Settings

@Observable
private final class SessionsSettingsViewModel {
    var devices: [DeviceInfo] = []
    var isSessionVerified = false
    var isLoading = true
    var errorMessage: String?

    @MainActor
    func load(service: any MatrixServiceProtocol) async {
        do {
            async let devicesTask = service.getDevices()
            async let verifiedTask = service.isCurrentSessionVerified()
            devices = try await devicesTask.sorted(by: Self.deviceOrder)
            isSessionVerified = await verifiedTask
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    nonisolated static func deviceOrder(_ lhs: DeviceInfo, _ rhs: DeviceInfo) -> Bool {
        if lhs.isCurrentDevice { return true }
        if rhs.isCurrentDevice { return false }
        if let l = lhs.lastSeenTimestamp, let r = rhs.lastSeenTimestamp { return l > r }
        if lhs.lastSeenTimestamp != nil { return true }
        if rhs.lastSeenTimestamp != nil { return false }
        return lhs.id < rhs.id
    }
}

private struct VerificationItem: Identifiable {
    let id = UUID()
    let viewModel: any SessionVerificationViewModelProtocol
}

private struct SessionsSettingsTab: View {
    @Environment(\.matrixService) private var matrixService
    @State private var viewModel = SessionsSettingsViewModel()
    @State private var verificationItem: VerificationItem?

    var body: some View {
        Form {
            if viewModel.isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            } else if viewModel.devices.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "desktopcomputer",
                        description: Text("No device information is available.")
                    )
                }
            } else {
                let current = viewModel.devices.filter(\.isCurrentDevice)
                let others = viewModel.devices.filter { !$0.isCurrentDevice }

                if let device = current.first {
                    Section("Current Session") {
                        DeviceRow(device: device, isVerified: viewModel.isSessionVerified)
                    }
                }

                if others.count > 0 {
                    Section {
                        Button {
                            Task {
                                do {
                                    if let vm = try await matrixService.makeSessionVerificationViewModel() {
                                        verificationItem = VerificationItem(viewModel: vm)
                                    }
                                } catch {
                                    viewModel.errorMessage = error.localizedDescription
                                }
                            }
                        } label: {
                            Label("Verify with Another Device", systemImage: "checkmark.shield")
                        }
                    } footer: {
                        Text("Compare emoji on both devices to confirm your identity.")
                    }
                }

                if !others.isEmpty {
                    Section("Other Sessions") {
                        ForEach(others) { device in
                            DeviceRow(device: device)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await viewModel.load(service: matrixService) }
        .alert("Sessions Error", isPresented: showErrorBinding) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .sheet(item: $verificationItem) { item in
            VerificationSheet(viewModel: item.viewModel)
        }
    }

    private var showErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

// MARK: - Verification Sheet

private struct VerificationSheet: View {
    var viewModel: any SessionVerificationViewModelProtocol
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.state {
            case .idle:
                idleView
            case .requesting, .waitingForOtherDevice, .sasStarted:
                waitingView
            case .showingEmojis:
                emojiView
            case .verified:
                resultView(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    title: "Verified!",
                    detail: "This session has been successfully verified."
                )
            case .cancelled:
                resultView(
                    icon: "xmark.circle.fill",
                    color: .secondary,
                    title: "Cancelled",
                    detail: "Verification was cancelled."
                )
            case .failed(let message):
                resultView(
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    title: "Verification Failed",
                    detail: message
                )
            }
        }
        .frame(width: 380, height: 340)
        .alert("Error", isPresented: showErrorBinding) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.shield")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Verify Session")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Confirm your identity by comparing emoji on this device and another signed-in session.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Verification") {
                    Task { await viewModel.requestVerification() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    // MARK: - Waiting

    private var waitingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Waiting for Other Device")
                .font(.title3)
                .fontWeight(.medium)
            Text("Accept the verification request on your other device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") {
                    Task { await viewModel.cancelVerification() }
                }
            }
            .padding()
        }
    }

    // MARK: - Emoji Comparison

    private var emojiView: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Compare Emoji")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Confirm that the following emoji appear on both devices, in the same order.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(spacing: 12) {
                let topRow = Array(viewModel.emojis.prefix(4))
                let bottomRow = Array(viewModel.emojis.dropFirst(4))
                HStack(spacing: 0) {
                    ForEach(topRow) { emoji in
                        emojiCell(emoji)
                            .frame(maxWidth: .infinity)
                    }
                }
                HStack(spacing: 0) {
                    ForEach(bottomRow) { emoji in
                        emojiCell(emoji)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Spacer()
            HStack {
                Button("They Don\u{2019}t Match", role: .destructive) {
                    Task { await viewModel.declineVerification() }
                }
                Spacer()
                Button("They Match") {
                    Task { await viewModel.approveVerification() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    private func emojiCell(_ emoji: VerificationEmoji) -> some View {
        VStack(spacing: 4) {
            Text(emoji.symbol)
                .font(.system(size: 32))
            Text(emoji.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
    }

    // MARK: - Result

    private func resultView(icon: String, color: Color, title: String, detail: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(color)
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    private var showErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

private struct DeviceRow: View {
    let device: DeviceInfo
    var isVerified: Bool?

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var iconName: String {
        if device.isCurrentDevice {
            return (isVerified == true) ? "checkmark.shield.fill" : "xmark.shield.fill"
        }
        return "desktopcomputer"
    }

    private var iconColor: Color {
        if device.isCurrentDevice {
            return (isVerified == true) ? .green : .red
        }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.displayName ?? "Unknown device")
                        .fontWeight(.medium)
                    if device.isCurrentDevice {
                        Text("This device")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.green.opacity(0.12), in: Capsule())
                    }
                }

                HStack(spacing: 4) {
                    Text(device.id)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)

                    if let ts = device.lastSeenTimestamp {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(Self.relativeDateFormatter.localizedString(for: ts, relativeTo: .now))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let ip = device.lastSeenIP {
                    Text(ip)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Encryption Settings

private struct EncryptionSettingsTab: View {
    @Environment(\.matrixService) private var matrixService
    @State private var isSessionVerified = false
    @State private var isRecoveryEnabled = false
    @State private var isBackupEnabled = false

    var body: some View {
        Form {
            Section {
                statusRow(
                    icon: isSessionVerified ? "checkmark.shield.fill" : "xmark.shield.fill",
                    color: isSessionVerified ? .green : .red,
                    title: isSessionVerified ? "Session Verified" : "Session Not Verified",
                    detail: isSessionVerified
                        ? "This device has been verified by another session."
                        : "Verify this session from another device to enable cross-signing."
                )
            } header: {
                Text("Identity Verification")
                Text("Allows you to verify other Matrix accounts and automatically trust their verified sessions.")
            }

            Section {
                statusRow(
                    icon: isBackupEnabled ? "arrow.triangle.2.circlepath" : "exclamationmark.arrow.triangle.2.circlepath",
                    color: isBackupEnabled ? .green : .orange,
                    title: isBackupEnabled ? "Key Backup Enabled" : "Key Backup Not Active",
                    detail: isBackupEnabled
                        ? "Message keys are being backed up to the server."
                        : "Message keys are not being backed up. You may lose access to encrypted history."
                )
            } header: {
                Text("Key Backup")
            }

            Section {
                statusRow(
                    icon: isRecoveryEnabled ? "key.fill" : "key",
                    color: isRecoveryEnabled ? .green : .orange,
                    title: isRecoveryEnabled ? "Recovery Enabled" : "Recovery Not Set Up",
                    detail: isRecoveryEnabled
                        ? "You can recover your encrypted messages if you lose all sessions."
                        : "Set up a recovery key to protect against losing access to your messages."
                )
            } header: {
                Text("Account Recovery")
                Text("Recover your account with a recovery key or passphrase if you lose access to all sessions.")
            }
        }
        .formStyle(.grouped)
        .task { await loadState() }
    }

    private func loadState() async {
        isSessionVerified = await matrixService.isCurrentSessionVerified()
        let encryption = await matrixService.encryptionState()
        isBackupEnabled = encryption.backupEnabled
        isRecoveryEnabled = encryption.recoveryEnabled
    }

    private func statusRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Previews

#Preview("General") {
    SettingsView()
        .environment(\.matrixService, PreviewMatrixService())
}
#Preview("Notifications") {
    TabView {
        NotificationSettingsTab()
            .tabItem { Label("Notifications", systemImage: "bell") }
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 480)
}

#Preview("Behavior") {
    TabView {
        BehaviorSettingsTab()
            .tabItem { Label("Behavior", systemImage: "gearshape") }
    }
    .frame(width: 480)
}

#Preview("Sessions") {
    TabView {
        SessionsSettingsTab()
            .tabItem { Label("Sessions", systemImage: "desktopcomputer") }
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 480)
}

#Preview("Verification — Emoji") {
    VerificationSheet(
        viewModel: PreviewSessionVerificationViewModel(
            state: .showingEmojis,
            emojis: PreviewSessionVerificationViewModel.sampleEmojis
        )
    )
}

#Preview("Verification — Idle") {
    VerificationSheet(viewModel: PreviewSessionVerificationViewModel())
}

#Preview("Encryption") {
    TabView {
        EncryptionSettingsTab()
            .tabItem { Label("Encryption", systemImage: "lock.fill") }
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 480)
}

