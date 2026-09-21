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

/// A reusable invite-by-Matrix-ID section with a text field, send button,
/// validation, and a list of successfully invited users.
///
/// Used by ``InviteToSpaceSheet`` and ``InspectorMembersTab`` to share
/// the invite flow logic.
struct InviteUserSection: View {
    /// The room or space to invite the user to.
    let roomId: String

    @Environment(RelayClient.self) private var client
    @Environment(\.errorReporter) private var errorReporter

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
        HStack {
            TextField("Matrix ID", text: $userId, prompt: Text("@user:server.org"))
                .focused($isFieldFocused)
                .autocorrectionDisabled()
                .onSubmit { sendInvite() }

            Button("Invite", systemImage: "paperplane") {
                sendInvite()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isValidUserId || isSending)
        }

        ForEach(sentUserIds, id: \.self) { invitedId in
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(invitedId)
                    .font(.callout)
            }
        }
    }

    /// Focuses the text field. Call from `onAppear` when appropriate.
    func focus() {
        isFieldFocused = true
    }

    private func sendInvite() {
        let trimmed = userId.trimmingCharacters(in: .whitespaces)
        guard isValidUserId, !isSending else { return }
        isSending = true

        Task {
            do {
                try await client.inviteUser(roomId: roomId, userId: trimmed)
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
