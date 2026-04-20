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

/// The Encryption tab of the Settings window, displaying read-only status
/// information for session verification, key backup, and account recovery.
struct SettingsEncryptionTab: View {
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
                // swiftlint:disable:next line_length
                Text("Allows you to verify other Matrix accounts and automatically trust their verified sessions.")
            }

            Section {
                statusRow(
                    // swiftlint:disable:next line_length
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
                // swiftlint:disable:next line_length
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

#Preview {
    TabView {
        SettingsEncryptionTab()
            .tabItem { Label("Encryption", systemImage: "lock.fill") }
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 480)
}
