import RelayCore
import SwiftUI

// MARK: - Settings View

struct SettingsView: View {
    @Environment(\.matrixService) private var matrixService

    var body: some View {
        Group {
            if matrixService.userId() != nil {
                TabView {
                    GeneralSettingsTab()
                        .tabItem { Label("General", systemImage: "gear") }
                    NotificationSettingsTab()
                        .tabItem { Label("Notifications", systemImage: "bell") }
                    SafetySettingsTab()
                        .tabItem { Label("Safety", systemImage: "hand.raised.fill") }
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

// MARK: - General Tab

private struct GeneralSettingsTab: View {
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

private struct SafetySettingsTab: View {
    @AppStorage("safety.sendReadReceipts") private var sendReadReceipts = true
    @AppStorage("safety.sendTypingNotifications") private var sendTypingNotifications = true
    @AppStorage("safety.mediaPreviewMode") private var mediaPreviewMode = MediaPreviewMode.privateOnly

    var body: some View {
        Form {
            Section("Privacy") {
                Toggle("Send Read Receipts", isOn: $sendReadReceipts)
                Toggle("Send Typing Notifications", isOn: $sendTypingNotifications)
            } 

            Section {
                Picker("Show Previews In", selection: $mediaPreviewMode) {
                    ForEach(MediaPreviewMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Media Previews")
                Text("Hidden previews can always be revealed by clicking on the media.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Sessions Settings

@Observable
private final class SessionsSettingsViewModel {
    var devices: [DeviceInfo] = []
    var isLoading = true
    var errorMessage: String?

    @MainActor
    func load(service: any MatrixServiceProtocol) async {
        do {
            devices = try await service.getDevices().sorted { lhs, rhs in
                if lhs.isCurrentDevice { return true }
                if rhs.isCurrentDevice { return false }
                switch (lhs.lastSeenTimestamp, rhs.lastSeenTimestamp) {
                case (.some(let l), .some(let r)): return l > r
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return lhs.id < rhs.id
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct SessionsSettingsTab: View {
    @Environment(\.matrixService) private var matrixService
    @State private var viewModel = SessionsSettingsViewModel()

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
                        DeviceRow(device: device)
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

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.isCurrentDevice ? "checkmark.circle.fill" : "desktopcomputer")
                .font(.title2)
                .foregroundStyle(device.isCurrentDevice ? .green : .secondary)
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
    var body: some View {
        Form {
            Section {
                statusRow(
                    icon: "checkmark.shield.fill",
                    color: .green,
                    title: "Crypto Identity Enabled",
                    detail: "This device is verified."
                )
            } header: {
                Text("Crypto Identity")
            } footer: {
                Text("Allows you to verify other Matrix accounts and automatically trust their verified sessions.")
            }

            Section {
                statusRow(
                    icon: "arrow.triangle.2.circlepath",
                    color: .green,
                    title: "Account Recovery Enabled",
                    detail: "Signing keys and encryption keys are synchronized."
                )
            } header: {
                Text("Account Recovery")
            } footer: {
                Text("Recover your account with a recovery key or passphrase if you lose access to all sessions.")
            }
        }
        .formStyle(.grouped)
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

#Preview("Safety") {
    TabView {
        SafetySettingsTab()
            .tabItem { Label("Safety", systemImage: "hand.raised.fill") }
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

#Preview("Encryption") {
    TabView {
        EncryptionSettingsTab()
            .tabItem { Label("Encryption", systemImage: "lock.fill") }
    }
    .frame(width: 480)
}

