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

/// A sheet for creating a new Matrix room with configurable options.
///
/// ``CreateRoomSheet`` presents a grouped form with fields for room name, topic,
/// address, visibility, and encryption. On submission it calls
/// ``MatrixServiceProtocol/createRoom(options:)`` and navigates to the new room.
struct CreateRoomSheet: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.dismiss) private var dismiss

    @Binding var selectedRoomId: String?

    @State private var name = ""
    @State private var topic = ""
    @State private var address = ""
    @State private var isPublic = false
    @State private var isEncrypted = true
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, topic, address
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            formContent
        }
        .frame(width: 420, height: 420)
        .onAppear { focusedField = .name }
        .alert("Room Creation Failed", isPresented: showingError, presenting: errorMessage) { _ in
            Button("OK") { errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Text("Create Room")
                .fontWeight(.semibold)

            Spacer()

            Button("Create") {
                createRoom()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isCreating)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Form

    private var formContent: some View {
        Form {
            Section("Details") {
                TextField("Name", text: $name, prompt: Text("e.g. Design Team, Book Club"))
                    .focused($focusedField, equals: .name)

                TextField("Topic", text: $topic, prompt: Text("What's this room about?"))
                    .focused($focusedField, equals: .topic)

                if isPublic {
                    TextField("Address", text: $address, prompt: Text("e.g. my-cool-room"))
                        .focused($focusedField, equals: .address)
                        .autocorrectionDisabled()
                }
            }

            Section {
                Picker("Visibility", selection: $isPublic) {
                    Text("Private").tag(false)
                    Text("Public").tag(true)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: isPublic) { _, newValue in
                    // Auto-adjust encryption default based on visibility.
                    isEncrypted = !newValue
                }

                Toggle("End-to-End Encryption", isOn: $isEncrypted)
            } header: {
                Text("Security & Access")
                Text(isPublic
                     ? "Anyone can find and join this room."
                     : "Only people with an invite can join this room.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private var showingError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func createRoom() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !isCreating else { return }
        isCreating = true
        errorMessage = nil

        Task {
            do {
                let trimmedTopic = topic.trimmingCharacters(in: .whitespaces)
                let trimmedAddress = address.trimmingCharacters(in: .whitespaces)

                let options = CreateRoomOptions(
                    name: trimmedName,
                    topic: trimmedTopic.isEmpty ? nil : trimmedTopic,
                    address: (isPublic && !trimmedAddress.isEmpty) ? trimmedAddress : nil,
                    isPublic: isPublic,
                    isEncrypted: isEncrypted
                )

                let roomId = try await matrixService.createRoom(options: options)
                selectedRoomId = roomId
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}

// MARK: - Previews

#Preview("Create Room") {
    CreateRoomSheet(selectedRoomId: .constant(nil))
        .environment(\.matrixService, PreviewMatrixService())
}
