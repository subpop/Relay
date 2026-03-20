import RelayCore
import SwiftUI

struct ContentView: View {
    @Environment(\.matrixService) private var matrixService

    var body: some View {
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
                if matrixService.syncState == .idle {
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
                    .onAppear { matrixService.startSyncIfNeeded() }
                } else {
                    MainView()
                }
            case .error(let message):
                LoginView(initialError: message)
            }
        }
        .frame(minWidth: 700, minHeight: 450)
    }
}

#Preview {
    ContentView()
}
