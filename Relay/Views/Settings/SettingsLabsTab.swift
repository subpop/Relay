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

/// The Labs tab of the Settings window, providing opt-in experimental features.
struct SettingsLabsTab: View {
    @Environment(RelayClient.self) private var client
    @AppStorage(RelayClient.slidingSyncLabsKey) private var slidingSync = false

    var body: some View {
        Form {
            Section {
                Toggle("Sliding sync", isOn: $slidingSync)
                    .disabled(!client.canUseSlidingSync)
                Text(footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Sync Experiments")
            }
        }
        .formStyle(.grouped)
    }

    private var footnote: String {
        if !client.canUseSlidingSync {
            "Your homeserver doesn't advertise simplified sliding sync."
        } else if slidingSync, !isLoggedIn {
            "Applies the next time you sign in."
        } else if slidingSync {
            "Sliding sync is on. It replaces the classic sync loop and applies immediately."
        } else {
            "Use the experimental simplified sliding sync transport instead of the classic sync loop."
        }
    }

    private var isLoggedIn: Bool {
        if case .loggedIn = client.authState { true } else { false }
    }
}

#Preview {
    TabView {
        SettingsLabsTab()
            .tabItem { Label("Labs", systemImage: "flask") }
    }
    .frame(width: 480)
    .environment(RelayClient())
}
