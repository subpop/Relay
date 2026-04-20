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

/// A sheet for creating a new sub-space inside an existing parent space.
///
/// ``CreateSubSpaceSheet`` presents a form identical to ``CreateSpaceSheet`` but
/// automatically adds the newly created space as a child of the parent space
/// via ``MatrixServiceProtocol/addChildToSpace(childId:spaceId:)``.
struct CreateSubSpaceSheet: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.errorReporter) private var errorReporter

    /// The Matrix room ID of the parent space.
    let parentSpaceId: String

    /// The display name of the parent space (shown in the title).
    let parentSpaceName: String

    @State private var name = ""
    @State private var topic = ""
    @State private var address = ""
    @State private var isPublic = false
    @State private var isCreating = false
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
        .frame(width: 420, height: 380)
        .onAppear { focusedField = .name }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            VStack(spacing: 2) {
                Text("Create Sub-Space")
                    .fontWeight(.semibold)
                Text("in \(parentSpaceName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Create") {
                createSubSpace()
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
                TextField("Name", text: $name, prompt: Text("e.g. Backend, Design"))
                    .focused($focusedField, equals: .name)

                TextField("Topic", text: $topic, prompt: Text("What\u{2019}s this sub-space for?"))
                    .focused($focusedField, equals: .topic)

                if isPublic {
                    TextField("Address", text: $address, prompt: Text("e.g. my-sub-space"))
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
            } header: {
                Text("Access")
                Text(isPublic
                     ? "Anyone can find and join this sub-space."
                     : "Only people with an invite can join this sub-space.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private func createSubSpace() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !isCreating else { return }
        isCreating = true

        Task {
            do {
                let trimmedTopic = topic.trimmingCharacters(in: .whitespaces)
                let trimmedAddress = address.trimmingCharacters(in: .whitespaces)

                let options = CreateRoomOptions(
                    name: trimmedName,
                    topic: trimmedTopic.isEmpty ? nil : trimmedTopic,
                    address: (isPublic && !trimmedAddress.isEmpty) ? trimmedAddress : nil,
                    isPublic: isPublic,
                    isEncrypted: false,
                    isSpace: true
                )

                let newSpaceId = try await matrixService.createRoom(options: options)
                try await matrixService.addChildToSpace(childId: newSpaceId, spaceId: parentSpaceId)
                dismiss()
            } catch {
                errorReporter.report(.roomCreationFailed(error.localizedDescription))
                isCreating = false
            }
        }
    }
}

// MARK: - Previews

#Preview {
    CreateSubSpaceSheet(
        parentSpaceId: "!space-work:matrix.org",
        parentSpaceName: "Work"
    )
    .environment(\.matrixService, PreviewMatrixService())
}
