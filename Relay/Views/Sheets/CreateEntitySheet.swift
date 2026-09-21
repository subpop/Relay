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

/// A sheet for creating a new Matrix room, space, or sub-space.
///
/// Pass an ``EntityKind`` to configure the title, placeholders, and
/// post-creation behavior. For rooms, an encryption toggle is shown and
/// the sheet navigates to the new room on success. For sub-spaces, the
/// new space is automatically added as a child of the parent.
struct CreateEntitySheet: View {
    /// The kind of entity to create.
    enum EntityKind {
        /// A regular room with optional encryption.
        case room
        /// A top-level space.
        case space
        /// A sub-space inside an existing parent.
        case subSpace(parentId: String, parentName: String)
    }

    @Environment(RelayClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Environment(\.errorReporter) private var errorReporter

    let kind: EntityKind

    /// Binding for navigating to the new room after creation (room only).
    var selectedRoomId: Binding<String?>?

    @State private var name = ""
    @State private var topic = ""
    @State private var address = ""
    @State private var isPublic = false
    @State private var isEncrypted = true
    @State private var isCreating = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, topic, address
    }

    // MARK: - Derived Properties

    private var title: String {
        switch kind {
        case .room: "Create Room"
        case .space: "Create Space"
        case .subSpace: "Create Sub-Space"
        }
    }

    private var subtitle: String? {
        if case .subSpace(_, let parentName) = kind {
            return "in \(parentName)"
        }
        return nil
    }

    private var subSpaceParentId: String? {
        if case .subSpace(let parentId, _) = kind {
            return parentId
        }
        return nil
    }

    private var namePlaceholder: String {
        switch kind {
        case .room: "e.g. Design Team, Book Club"
        case .space: "e.g. Engineering, Community"
        case .subSpace: "e.g. Backend, Design"
        }
    }

    private var topicPlaceholder: String {
        switch kind {
        case .room: "What\u{2019}s this room about?"
        case .space: "What\u{2019}s this space for?"
        case .subSpace: "What\u{2019}s this sub-space for?"
        }
    }

    private var addressPlaceholder: String {
        switch kind {
        case .room: "e.g. my-cool-room"
        case .space: "e.g. my-space"
        case .subSpace: "e.g. my-sub-space"
        }
    }

    private var accessSectionTitle: String {
        switch kind {
        case .room: "Security & Access"
        case .space, .subSpace: "Access"
        }
    }

    private var entityName: String {
        switch kind {
        case .room: "room"
        case .space: "space"
        case .subSpace: "sub-space"
        }
    }

    private var showEncryptionToggle: Bool {
        if case .room = kind { return true }
        return false
    }

    private var isSpace: Bool {
        switch kind {
        case .room: false
        case .space, .subSpace: true
        }
    }

    private var frameHeight: CGFloat {
        switch kind {
        case .room: 420
        case .space: 360
        case .subSpace: 380
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            formContent
        }
        .frame(width: 420, height: frameHeight)
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
                Text(title)
                    .fontWeight(.semibold)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button("Create") {
                create()
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
                TextField("Name", text: $name, prompt: Text(namePlaceholder))
                    .focused($focusedField, equals: .name)

                TextField("Topic", text: $topic, prompt: Text(topicPlaceholder))
                    .focused($focusedField, equals: .topic)

                if isPublic {
                    TextField("Address", text: $address, prompt: Text(addressPlaceholder))
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
                .onChange(of: isPublic) {
                    if showEncryptionToggle {
                        isEncrypted = !isPublic
                    }
                }

                if showEncryptionToggle, !isPublic {
                    Toggle("End-to-End Encryption", isOn: $isEncrypted)
                }
            } header: {
                Text(accessSectionTitle)
                Text(isPublic
                     ? "Anyone can find and join this \(entityName)."
                     : "Only people with an invite can join this \(entityName).")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Actions

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !isCreating else { return }
        isCreating = true

        Task {
            do {
                let trimmedTopic = topic.trimmingCharacters(in: .whitespaces)
                let trimmedAddress = address.trimmingCharacters(in: .whitespaces)

                let roomId = try await client.createRoom(
                    name: trimmedName,
                    topic: trimmedTopic.isEmpty ? nil : trimmedTopic,
                    address: (isPublic && !trimmedAddress.isEmpty) ? trimmedAddress : nil,
                    isPublic: isPublic,
                    isEncrypted: isSpace ? false : isEncrypted,
                    isSpace: isSpace,
                    parentSpaceId: subSpaceParentId
                )

                if case .subSpace(let parentId, _) = kind {
                    try await client.addChildToSpace(childId: roomId, spaceId: parentId)
                }

                if case .room = kind {
                    selectedRoomId?.wrappedValue = roomId
                }

                dismiss()
            } catch {
                errorReporter.report(.roomCreationFailed(error.localizedDescription))
                isCreating = false
            }
        }
    }
}

// MARK: - Previews

#Preview("Create Room") {
    CreateEntitySheet(kind: .room, selectedRoomId: .constant(nil))
        .environment(RelayClient())
}

#Preview("Create Space") {
    CreateEntitySheet(kind: .space)
        .environment(RelayClient())
}

#Preview("Create Sub-Space") {
    CreateEntitySheet(
        kind: .subSpace(parentId: "!space-work:matrix.org", parentName: "Work")
    )
    .environment(RelayClient())
}
