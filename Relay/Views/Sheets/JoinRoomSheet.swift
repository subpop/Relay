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

/// A sheet for joining an existing Matrix room by room ID or alias.
///
/// ``JoinRoomSheet`` presents a simple form with a single text field accepting
/// a room identifier (e.g. `!abc:matrix.org` or `#room:matrix.org`). On submission
/// it calls ``MatrixServiceProtocol/joinRoom(idOrAlias:)`` and navigates to the
/// joined room.
struct JoinRoomSheet: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.errorReporter) private var errorReporter

    @Binding var selectedRoomId: String?

    @State private var roomIdentifier = ""
    @State private var isJoining = false
    @FocusState private var isFieldFocused: Bool

    private var trimmedIdentifier: String {
        roomIdentifier.trimmingCharacters(in: .whitespaces)
    }

    private var isValid: Bool {
        let id = trimmedIdentifier
        return id.hasPrefix("!") || id.hasPrefix("#")
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

            Text("Join Room")
                .fontWeight(.semibold)

            Spacer()

            Button("Join") {
                joinRoom()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid || isJoining)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Form

    private var formContent: some View {
        Form {
            Section {
                TextField("Room ID or Alias", text: $roomIdentifier,
                          prompt: Text("e.g. #room:matrix.org or !abc:matrix.org"))
                    .focused($isFieldFocused)
                    .autocorrectionDisabled()
                    .onSubmit {
                        if isValid && !isJoining {
                            joinRoom()
                        }
                    }
            } footer: {
                Text("Enter a room ID (starting with !) or alias (starting with #).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func joinRoom() {
        let identifier = trimmedIdentifier
        guard isValid, !isJoining else { return }
        isJoining = true

        Task {
            do {
                try await matrixService.joinRoom(idOrAlias: identifier)

                // Wait briefly for the room list to sync.
                try? await Task.sleep(for: .milliseconds(500))
                if let joined = matrixService.rooms.first(where: {
                    $0.id == identifier || $0.canonicalAlias == identifier
                }) {
                    selectedRoomId = joined.id
                }
                dismiss()
            } catch {
                errorReporter.report(.roomJoinFailed(error.localizedDescription))
                isJoining = false
            }
        }
    }
}

// MARK: - Previews

#Preview("Join Room") {
    JoinRoomSheet(selectedRoomId: .constant(nil))
        .environment(\.matrixService, PreviewMatrixService())
}
