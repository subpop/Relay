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

import SwiftUI

// MARK: - Key Backup Setup Sheet

/// A sheet that creates the account's first key backup and shows the
/// recovery key, once, for the user to keep.
struct KeyBackupSetupSheet: View {
    @Bindable var viewModel: KeyBackupSetupViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack {
            switch viewModel.state {
            case .intro:
                introView
            case .creating:
                creatingView
            case .created(let recoveryKey):
                createdView(recoveryKey: recoveryKey)
            case .failed(let message):
                failedView(message: message)
            }
        }
        .frame(width: 400, height: 420)
        .interactiveDismissDisabled(!viewModel.canFinish)
    }

    // MARK: - Intro

    private var introView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Set Up Key Backup")
                .font(.title2)
                .bold()
            Text("Relay will back up the keys that decrypt your messages to your homeserver, encrypted so that only you can read them.")
                .multilineTextAlignment(.center)
            Text("You will get a recovery key. Keep it somewhere safe: it restores your message history on a new device when none of your other devices can share the key.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Keys already on this device join the backup as Relay reads your message history, so older messages may not be covered at first.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create Backup") {
                    Task { await viewModel.createBackup() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    // MARK: - Creating

    private var creatingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Creating Backup")
                .font(.title3)
            Spacer()
        }
        .padding()
    }

    // MARK: - Created

    private func createdView(recoveryKey: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.green)
            Text("Your Recovery Key")
                .font(.title2)
                .bold()
            Text("Save this key now. It will not be shown again.")
                .multilineTextAlignment(.center)

            Text(recoveryKey)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: .rect(cornerRadius: 8))

            Button(
                viewModel.didCopyRecoveryKey ? "Copied" : "Copy Recovery Key",
                systemImage: viewModel.didCopyRecoveryKey ? "checkmark" : "doc.on.doc"
            ) {
                viewModel.copyRecoveryKey()
            }

            Spacer()
            Toggle("I have saved my recovery key", isOn: $viewModel.hasSavedRecoveryKey)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canFinish)
            }
        }
        .padding()
    }

    // MARK: - Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.red)
            Text("Could Not Set Up Backup")
                .font(.title2)
                .bold()
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Try Again") {
                    Task { await viewModel.createBackup() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}

#Preview("Intro") {
    KeyBackupSetupSheet(viewModel: KeyBackupSetupViewModel(create: { "Es00 0000" }))
}

#Preview("Created") {
    let model = KeyBackupSetupViewModel(create: {
        "EsTa 1b2c 3d4e 5f6a 7b8c 9d0e 1f2a 3b4c 5d6e 7f8a"
    })
    return KeyBackupSetupSheet(viewModel: model)
        .task { await model.createBackup() }
}
