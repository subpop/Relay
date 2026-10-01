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

/// The root view that switches between login, loading, and main content based on auth state.
struct ContentView: View {
    @Environment(RelayClient.self) private var client

    var body: some View {
        Group {
            switch client.authState {
            case .unknown:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loggedOut:
                LoginView()
            case .loggingIn:
                ProgressView("Signing in…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loggedIn:
                switch client.syncState {
                case .idle:
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Syncing your rooms…")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("This may take a moment on first sign-in.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { client.startSyncIfNeeded() }
                case .syncing, .running, .offline:
                    MainView()
                case .error:
                    MainView()
                }
            case .error:
                LoginView()
            }
        }
        // Attached to the outer Group (stable identity): restoring flips
        // authState, which swaps the inner branch and would cancel a
        // branch-attached task mid-sync on every launch.
        .task {
            await client.restoreSession()
        }
        .alert(
            "Session Signed Out",
            isPresented: Binding(
                get: { client.remoteSignOutNoticed },
                set: {
                    // No recovery path exists: any dismissal (including
                    // Escape) signs out and returns to the login screen.
                    if !$0, client.remoteSignOutNoticed {
                        Task { await client.logout() }
                    } else {
                        client.remoteSignOutNoticed = $0
                    }
                }
            )
        ) {
            Button("Log out") {
                Task { await client.logout() }
            }
        } message: {
            Text(
                "This session was signed out from another device or the homeserver's session management page. Sign in again to continue."
            )
        }
        .relayErrorAlert()
    }
}

#Preview {
    ContentView()
        .environment(PreviewFixtures.previewClient())
}
