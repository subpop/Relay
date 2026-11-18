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

/// The settings window, organized into sidebar pages for account profile,
/// appearance, behavior, notifications, session management, encryption status, and labs.
struct SettingsView: View {
    @Environment(RelayClient.self) private var client
    @State private var destination: SettingsDestination? = .account

    var body: some View {
        Group {
            if client.userId() != nil {
                NavigationSplitView {
                    List(selection: $destination) {
                        ForEach(SettingsDestination.allCases) { destination in
                            destination.label.tag(destination)
                        }
                    }
                    .navigationTitle("Settings")
                    .frame(minWidth: 170)
                } detail: {
                    switch destination ?? .account {
                    case .account:
                        SettingsAccountTab()
                    case .appearance:
                        SettingsAppearanceTab()
                    case .behavior:
                        SettingsBehaviorTab()
                    case .notifications:
                        SettingsNotificationsTab()
                    case .sessions:
                        SettingsSessionsTab()
                    case .encryption:
                        SettingsEncryptionTab()
                    case .labs:
                        SettingsLabsTab()
                    }
                }
            } else {
                ContentUnavailableView(
                    "Not Signed In",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Sign in to access settings.")
                )
            }
        }
        .frame(minWidth: 800, minHeight: 560)
    }
}

private enum SettingsDestination: CaseIterable, Hashable, Identifiable {
    case account
    case appearance
    case behavior
    case notifications
    case sessions
    case encryption
    case labs

    var id: Self { self }

    var label: Label<Text, Image> {
        switch self {
        case .account: Label("Account", systemImage: "person.crop.circle")
        case .appearance: Label("Appearance", systemImage: "paintbrush")
        case .behavior: Label("Behavior", systemImage: "gearshape")
        case .notifications: Label("Notifications", systemImage: "bell")
        case .sessions: Label("Sessions", systemImage: "desktopcomputer")
        case .encryption: Label("Encryption", systemImage: "lock.fill")
        case .labs: Label("Labs", systemImage: "flask")
        }
    }
}

// MARK: - Previews

#Preview("Settings") {
    SettingsView()
        .environment(PreviewFixtures.previewClient())
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
