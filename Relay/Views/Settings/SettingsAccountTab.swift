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

/// The Account tab of the Settings window, displaying the user's profile avatar,
/// display name (with debounced save), user ID, and a logout action.
struct SettingsAccountTab: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter

    @State private var displayName = ""
    @State private var savedDisplayName = ""
    @State private var avatarURL: String?
    @State private var showLogoutConfirmation = false
    @State private var displayNameSaveTask: Task<Void, Never>?

    private var userId: String? { matrixService.userId() }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AvatarView(
                        name: displayName.isEmpty ? (userId ?? "?") : displayName,
                        mxcURL: avatarURL,
                        size: 64
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName.isEmpty ? "Not set" : displayName)
                            .font(.title3)
                            .fontWeight(.medium)
                        if let userId {
                            Text(userId)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, 4)

                Button("Log Out…", role: .destructive) {
                    showLogoutConfirmation = true
                }
                .controlSize(.small)
            }

            Section("Profile") {
                TextField("Display Name", text: $displayName)

                if let userId {
                    LabeledContent("User ID") {
                        HStack(spacing: 6) {
                            Text(userId)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(userId, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.borderless)
                            .help("Copy User ID")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            let name = await matrixService.userDisplayName() ?? ""
            displayName = name
            savedDisplayName = name
            avatarURL = await matrixService.userAvatarURL()
        }
        .onChange(of: displayName) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != savedDisplayName else { return }
            displayNameSaveTask?.cancel()
            displayNameSaveTask = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                do {
                    try await matrixService.setDisplayName(trimmed)
                } catch {
                    errorReporter.report(.displayNameUpdateFailed(error.localizedDescription))
                }
                savedDisplayName = trimmed
            }
        }
        .alert("Log Out", isPresented: $showLogoutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Log Out", role: .destructive) {
                Task { await matrixService.logout() }
            }
        } message: {
            Text("Are you sure you want to log out? You will need to sign in again.")
        }
    }
}

#Preview {
    TabView {
        SettingsAccountTab()
            .tabItem { Label("Account", systemImage: "person.crop.circle") }
    }
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 480)
}
