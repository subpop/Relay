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

// MARK: - Settings View

/// The settings window, organized into tabs for account profile, appearance,
/// behavior, notifications, session management, and encryption status.
struct SettingsView: View {
    @Environment(\.matrixService) private var matrixService

    var body: some View {
        Group {
            if matrixService.userId() != nil {
                TabView {
                    SettingsAccountTab()
                        .tabItem { Label("Account", systemImage: "person.crop.circle") }
                    SettingsAppearanceTab()
                        .tabItem { Label("Appearance", systemImage: "paintbrush") }
                    SettingsBehaviorTab()
                        .tabItem { Label("Behavior", systemImage: "gearshape") }
                    SettingsNotificationsTab()
                        .tabItem { Label("Notifications", systemImage: "bell") }
                    SettingsSessionsTab()
                        .tabItem { Label("Sessions", systemImage: "desktopcomputer") }
                    SettingsEncryptionTab()
                        .tabItem { Label("Encryption", systemImage: "lock.fill") }
                }
            } else {
                ContentUnavailableView(
                    "Not Signed In",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Sign in to access settings.")
                )
            }
        }
        .frame(width: 480)
    }
}

// MARK: - Previews

#Preview("General") {
    SettingsView()
        .environment(\.matrixService, PreviewMatrixService())
}

#Preview("Verification — Emoji") {
    VerificationSheet(
        viewModel: PreviewSessionVerificationViewModel(
            state: .showingEmojis,
            emojis: PreviewSessionVerificationViewModel.sampleEmojis
        )
    )
}

#Preview("Verification — Idle") {
    VerificationSheet(viewModel: PreviewSessionVerificationViewModel())
}
