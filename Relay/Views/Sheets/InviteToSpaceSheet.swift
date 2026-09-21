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

/// A sheet for inviting a user to a space by their Matrix user ID.
///
/// The user enters a Matrix ID (e.g. `@alice:matrix.org`) and the invite
/// is sent to the space room. The invited user will see the space appear
/// in their invite list.
struct InviteToSpaceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let spaceId: String
    let spaceName: String

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section {
                    InviteUserSection(roomId: spaceId)
                } header: {
                    Text("User")
                } footer: {
                    Text("Enter a full Matrix user ID including the server (e.g. @alice:matrix.org).")
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 400, height: 360)
    }

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
}

// MARK: - Previews

#Preview {
    InviteToSpaceSheet(
        spaceId: "!space-work:matrix.org",
        spaceName: "Work"
    )
    .environment(RelayClient())
}
