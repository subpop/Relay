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

/// A sheet for starting a direct-message conversation with a Matrix user.
///
/// ``NewDirectMessageSheet`` presents a simple form with a single text field
/// accepting a full user ID (e.g. `@alice:matrix.org`). On submission it
/// calls ``RelayClient/createDirectMessage(userId:)``, which reuses an
/// existing DM when one exists, and navigates to the resulting room.
struct NewDirectMessageSheet: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Environment(\.errorReporter) private var errorReporter

    @Binding var selectedRoomId: String?

    @State private var userId = ""
    @State private var isStarting = false
    @FocusState private var isFieldFocused: Bool

    private var trimmedUserId: String {
        userId.trimmingCharacters(in: .whitespaces)
    }

    private var isValid: Bool {
        let id = trimmedUserId
        guard id.hasPrefix("@") else { return false }
        let rest = id.dropFirst()
        return rest.contains(":") && !rest.hasPrefix(":") && !rest.hasSuffix(":")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            formContent
        }
        .frame(width: 420, height: 220)
        .onAppear { isFieldFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Text("New Direct Message")
                .fontWeight(.semibold)

            Spacer()

            Button("Message") {
                startConversation()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid || isStarting)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Form

    private var formContent: some View {
        Form {
            Section {
                TextField("User ID", text: $userId,
                          prompt: Text("e.g. @alice:matrix.org"))
                    .focused($isFieldFocused)
                    .autocorrectionDisabled()
                    .onSubmit {
                        if isValid && !isStarting {
                            startConversation()
                        }
                    }
            } footer: {
                Text("Enter the full Matrix ID of the user you want to message.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func startConversation() {
        let id = trimmedUserId
        guard isValid, !isStarting else { return }
        isStarting = true

        Task {
            do {
                selectedRoomId = try await client.createDirectMessage(userId: id)
                dismiss()
            } catch {
                errorReporter.report(.dmCreationFailed(error.localizedDescription))
                isStarting = false
            }
        }
    }
}

// MARK: - Previews

#Preview("New Direct Message") {
    NewDirectMessageSheet(selectedRoomId: .constant(nil))
        .environment(RelayClient())
}
