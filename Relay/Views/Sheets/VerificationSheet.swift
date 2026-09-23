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

// MARK: - Verification Sheet

/// A sheet that drives the interactive session verification flow.
///
/// Supports two verification methods:
/// - **SAS emoji comparison** — compare emoji across two devices.
/// - **Recovery key** — unlock 4S secret storage to verify directly,
///   without a second device, then optionally restore message history
///   from the account's key backup.
struct VerificationSheet: View {
    var viewModel: SessionVerificationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var recoveryInput = ""

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.state {
            case .idle:
                idleView
            case .requesting, .waitingForOtherDevice, .sasStarted:
                waitingView()
            case .waitingForApproval:
                approvingView
            case .awaitingBackupKey:
                waitingView(
                    title: "Checking for Message History",
                    detail: "Asking your other device for the backup key."
                )
            case .showingEmojis:
                emojiView
            case .enteringRecovery:
                recoveryView
            case .recovering:
                recoveryProgressView
            case .awaitingBackupRestore:
                restorePromptView
            case .verified:
                resultView(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    title: "Verified!",
                    detail: verifiedDetail
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
        .frame(width: 380, height: 400)
        .task {
            await viewModel.checkForOtherDevices()
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

            if viewModel.hasOtherDevices {
                Text("Choose how to verify this session.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text("No other devices found. Enter your recovery key to verify this session.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()

                if viewModel.hasOtherDevices {
                    Button("Recovery Key") {
                        viewModel.startRecoveryEntry()
                    }
                    Button("Another Device") {
                        Task { await viewModel.requestVerification() }
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Another Device") {
                        Task { await viewModel.requestVerification() }
                    }
                    Button("Recovery Key") {
                        viewModel.startRecoveryEntry()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
    }

    // MARK: - Waiting

    private func waitingView(
        title: String = "Waiting for Other Device",
        detail: String = "Accept the verification request on your other device."
    ) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.title3)
                .fontWeight(.medium)
            Text(detail)
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

    // MARK: - Recovery Progress

    /// 4S unlock with a determinate bar once the total is known,
    /// otherwise a spinner. Cancel stops the unlock.
    private var recoveryProgressView: some View {
        VStack(spacing: 16) {
            Spacer()
            if let fraction = viewModel.recoveryProgress?.fraction {
                ProgressView(value: fraction)
                    .padding(.horizontal, 48)
            } else {
                ProgressView()
                    .controlSize(.large)
            }
            Text("Recovering Keys")
                .font(.title3)
                .fontWeight(.medium)
            Text("Unlocking secret storage and importing keys.")
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

    // MARK: - Recovery Key Entry
    private var recoveryView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "key.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Enter Recovery Key")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Enter the recovery key you received when setting up account recovery.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)

            SecureField("Recovery Key", text: $recoveryInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 32)
                .onSubmit {
                    guard !recoveryInput.isEmpty else { return }
                    submitRecoveryKey()
                }

            Spacer()
            HStack {
                Button("Back") {
                    recoveryInput = ""
                    viewModel.resetToIdle()
                }
                Spacer()
                Button("Verify") {
                    submitRecoveryKey()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recoveryInput.isEmpty)
            }
            .padding()
        }
    }

    private func submitRecoveryKey() {
        let input = recoveryInput
        recoveryInput = ""
        Task { await viewModel.submitRecoveryKey(input) }
    }

    // MARK: - Backup Restore Prompt

    /// Success copy for the verified state. Notes when the restore
    /// continues in the background.
    private var verifiedDetail: String {
        if viewModel.restoreRunningInBackground {
            return "This session has been successfully verified. Message history is restoring in the background."
        } else {
            return "This session has been successfully verified."
        }
    }

    private var restorePromptView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Restore Message History")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Your account keeps a backup of message keys. Restore it to read earlier messages on this device.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            Spacer()
            HStack {
                Button("Skip") {
                    viewModel.skipBackupRestore()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore") {
                    Task { await viewModel.restoreBackup() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    // MARK: - Approving

    private var approvingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Completing Verification")
                .font(.title3)
                .fontWeight(.medium)
            Text("Waiting for the other device to confirm.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
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
                    ForEach(topRow, id: \.self) { emoji in
                        emojiCell(emoji)
                            .frame(maxWidth: .infinity)
                    }
                }
                HStack(spacing: 0) {
                    ForEach(bottomRow, id: \.self) { emoji in
                        emojiCell(emoji)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Spacer()
            HStack {
                Button("They Don’t Match", role: .destructive) {
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

    private func emojiCell(_ emoji: SASEmoji) -> some View {
        VStack(spacing: 4) {
            Text(emoji.emoji)
                .font(.system(size: 32))
            Text(emoji.description)
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
}
