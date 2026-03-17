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
    @State private var avatarURL: String?
    @State private var showLogoutConfirmation = false

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

            Section {
                HStack {
                    Spacer()
                    Button("Log Out…", role: .destructive) {
                        showLogoutConfirmation = true
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .task {
            displayName = await matrixService.userDisplayName() ?? ""
            avatarURL = await matrixService.userAvatarURL()
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

private enum NotificationMode: String, CaseIterable {
    case allMessages
    case directAndMentions
    case mentionsOnly

    var label: String {
        switch self {
        case .allMessages: "All messages"
        case .directAndMentions: "Direct messages, mentions, and keywords"
        case .mentionsOnly: "Mentions and keywords only"
        }
    }
}

private struct NotificationSettingsTab: View {
    @AppStorage("notifications.accountEnabled") private var accountEnabled = true
    @AppStorage("notifications.sessionEnabled") private var sessionEnabled = true
    @AppStorage("notifications.mode") private var notificationMode = NotificationMode.directAndMentions

    var body: some View {
        Form {
            Section("Enable Notifications") {
                Toggle("Enable for This Account", isOn: $accountEnabled)
                Toggle("Enable for This Session", isOn: $sessionEnabled)
            }

            Section {
                Picker("Default Level", selection: $notificationMode) {
                    ForEach(NotificationMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Default Notification Level")
            } footer: {
                Text("Controls which messages trigger notifications in rooms without specific rules.")
            }

            Section {
                Text("No keywords configured.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Keywords")
            } footer: {
                Text("Messages containing a keyword will trigger a notification. Matching is case-insensitive.")
            }
        }
        .formStyle(.grouped)
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
            } footer: {
                Text("Hidden previews can always be revealed by clicking on the media.")
            }
        }
        .formStyle(.grouped)
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
    .frame(width: 480)
}

#Preview("Safety") {
    TabView {
        SafetySettingsTab()
            .tabItem { Label("Safety", systemImage: "hand.raised.fill") }
    }
    .frame(width: 480)
}

#Preview("Encryption") {
    TabView {
        EncryptionSettingsTab()
            .tabItem { Label("Encryption", systemImage: "lock.fill") }
    }
    .frame(width: 480)
}

