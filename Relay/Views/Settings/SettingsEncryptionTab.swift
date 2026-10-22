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

/// The Encryption tab of the Settings window, displaying read-only status
/// information for session verification, key backup, and account recovery.
struct SettingsEncryptionTab: View {
    @Environment(RelayClient.self) private var client
    @State private var isSessionVerified = false
    @State private var isRecoveryEnabled = false
    @State private var backupStatus: KeyBackupStatus?
    @State private var isBackingUp = false
    @State private var setupModel: KeyBackupSetupViewModel?

    private var backup: KeyBackupPresentation {
        KeyBackupPresentation(status: backupStatus, isSessionVerified: isSessionVerified)
    }

    var body: some View {
        Form {
            Section {
                SecurityStatusRow(
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
                SecurityStatusRow(
                    icon: backup.icon,
                    color: backup.tone == .good ? .green : .orange,
                    title: backup.title,
                    detail: backup.detail
                )
                if backup.canBackUpNow {
                    HStack {
                        Button("Back Up Now") {
                            Task { await backUpNow() }
                        }
                        .disabled(isBackingUp)
                        if isBackingUp {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                if backup.canSetUp {
                    Button("Set Up Key Backup…") {
                        setupModel = KeyBackupSetupViewModel(
                            create: { try await client.setUpKeyBackup() })
                    }
                }
                if backup.canRestore, !client.keyFetch.isRestoring {
                    Button("Restore Key Backup") {
                        client.startBackupRestore()
                    }
                }
            } header: {
                Text("Key Backup")
            }

            Section {
                SecurityStatusRow(
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
        .sheet(item: $setupModel, onDismiss: {
            Task { backupStatus = await client.keyBackupStatus() }
        }, content: { model in
            KeyBackupSetupSheet(viewModel: model)
        })
        .onChange(of: client.keyFetch.isRestoring) {
            Task { backupStatus = await client.keyBackupStatus() }
        }
    }

    private func loadState() async {
        await client.refreshVerificationState()
        isSessionVerified = client.isSessionVerified
        let encryption = await client.encryptionStatus()
        isRecoveryEnabled = encryption.recoveryEnabled
        backupStatus = await client.keyBackupStatus()
    }

    private func backUpNow() async {
        isBackingUp = true
        defer { isBackingUp = false }
        if let status = await client.backUpKeysNow() {
            backupStatus = status
        }
    }

}

#Preview {
    TabView {
        SettingsEncryptionTab()
            .tabItem { Label("Encryption", systemImage: "lock.fill") }
    }
    .environment(PreviewFixtures.previewClient())
    .frame(width: 480)
}
