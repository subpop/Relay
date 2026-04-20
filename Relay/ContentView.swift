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

/// The root view that switches between login, loading, and main content based on ``AuthState``.
struct ContentView: View {
    @Environment(\.matrixService) private var matrixService

    var body: some View {
        let _ = Self._printChanges()
        Group {
            switch matrixService.authState {
            case .unknown:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { await matrixService.restoreSession() }
            case .loggedOut:
                LoginView()
            case .loggingIn:
                ProgressView("Signing in…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loggedIn:
                switch matrixService.syncState {
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
                    .task { matrixService.startSyncIfNeeded() }
                case .syncing, .running, .offline:
                    MainView()
                case .error:
                    MainView()
                }
            case .error:
                LoginView()
            }
        }
        .relayErrorAlert()
        .frame(minWidth: 700, minHeight: 500)
    }
}

#Preview {
    ContentView()
}
