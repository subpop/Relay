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

// MARK: - Verification Sheet

/// A sheet that drives the interactive session verification flow (SAS emoji comparison).
///
/// Presents different UI states as the verification progresses: idle, waiting,
/// emoji comparison, and result (verified/cancelled/failed). Used both from
/// Settings and from the verification banner when responding to incoming requests.
struct VerificationSheet: View {
    var viewModel: any SessionVerificationViewModelProtocol
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            switch viewModel.state {
            case .idle:
                idleView
            case .requesting, .waitingForOtherDevice, .sasStarted:
                waitingView
            case .waitingForApproval:
                approvingView
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

}
