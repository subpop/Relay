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

/// A sheet for inviting a user to a space by their Matrix user ID.
///
/// The user enters a Matrix ID (e.g. `@alice:matrix.org`) and the invite
/// is sent to the space room. The invited user will see the space appear
/// in their invite list.
struct InviteToSpaceSheet: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    @Environment(\.dismiss) private var dismiss

    let spaceId: String
    let spaceName: String

    @State private var userId = ""
    @State private var isSending = false
    @State private var sentUserIds: [String] = []
    @FocusState private var isFieldFocused: Bool

    /// Whether the current input looks like a valid Matrix user ID.
    private var isValidUserId: Bool {
        let trimmed = userId.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("@") && trimmed.contains(":")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 400, height: 360)
        .onAppear { isFieldFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Invite to \(spaceName)")
                .font(.headline)

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding()
    }

    // MARK: - Content

    private var content: some View {
        Form {
            Section {
                HStack {
                    TextField("Matrix ID", text: $userId, prompt: Text("@user:server.org"))
                        .focused($isFieldFocused)
                        .autocorrectionDisabled()
                        .onSubmit { sendInvite() }

                    Button("Invite", systemImage: "paperplane") {
                        sendInvite()
                    }
                    .buttonStyle(.bordered)
                    .tint(.accentColor)
                    .controlSize(.small)
                    .disabled(!isValidUserId || isSending)
                }
            } header: {
                Text("User")
            } footer: {
                Text("Enter a full Matrix user ID including the server (e.g. @alice:matrix.org).")
            }

            if !sentUserIds.isEmpty {
                Section("Invited") {
                    ForEach(sentUserIds, id: \.self) { invitedId in
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(invitedId)
                                .font(.callout)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private func sendInvite() {
        let trimmed = userId.trimmingCharacters(in: .whitespaces)
        guard isValidUserId, !isSending else { return }
        isSending = true

        Task {
            do {
                try await matrixService.inviteUser(roomId: spaceId, userId: trimmed)
                sentUserIds.append(trimmed)
                userId = ""
                isFieldFocused = true
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
            }
            isSending = false
        }
    }
}

// MARK: - Previews

#Preview {
    InviteToSpaceSheet(
        spaceId: "!space-work:matrix.org",
        spaceName: "Work"
    )
    .environment(\.matrixService, PreviewMatrixService())
}
