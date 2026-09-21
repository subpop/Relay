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

// MARK: - Settings View

/// The settings window, organized into tabs for account profile, appearance,
/// behavior, notifications, session management, encryption status, and labs.
struct SettingsView: View {
    @Environment(RelayClient.self) private var client

    var body: some View {
        Group {
            if client.userId() != nil {
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
                    SettingsLabsTab()
                        .tabItem { Label("Labs", systemImage: "flask") }
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
}

#Preview("Verification — Emoji") {
    VerificationSheet(viewModel: {
        let model = SessionVerificationViewModel(client: RelayClient())
        model.emojis = [
            SASEmoji(emoji: "🎉", description: "Party popper"),
            SASEmoji(emoji: "🚀", description: "Rocket"),
            SASEmoji(emoji: "🐶", description: "Dog face"),
            SASEmoji(emoji: "🌈", description: "Rainbow"),
            SASEmoji(emoji: "⚽", description: "Soccer ball"),
            SASEmoji(emoji: "🍕", description: "Pizza"),
            SASEmoji(emoji: "🎸", description: "Guitar"),
        ]
        model.state = .showingEmojis
        return model
    }())
}

#Preview("Verification — Idle") {
    VerificationSheet(viewModel: {
        let model = SessionVerificationViewModel(client: RelayClient())
        model.hasOtherDevices = true
        return model
    }())
}

#Preview("Verification — No Other Devices") {
    VerificationSheet(viewModel: SessionVerificationViewModel(client: RelayClient()))
}

#Preview("Verification — Recovery Entry") {
    VerificationSheet(viewModel: {
        let model = SessionVerificationViewModel(client: RelayClient())
        model.state = .enteringRecovery
        return model
    }())
}

#Preview("Verification — Restore Prompt") {
    VerificationSheet(viewModel: {
        let model = SessionVerificationViewModel(client: RelayClient())
        model.state = .awaitingBackupRestore
        return model
    }())
}
