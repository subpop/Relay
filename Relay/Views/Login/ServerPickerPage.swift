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

import AuthenticationServices
import RelayInterface
import SwiftUI

/// The server picker page where users choose a homeserver to create an account.
///
/// Displays a curated list of Matrix homeservers with "Log in with Browser"
/// buttons that trigger an OAuth/OIDC flow. Each server also has a "Learn more"
/// link. Additional servers and a directory link are available behind a
/// disclosure group.
struct ServerPickerPage: View {
    @Binding var step: LoginStep
    @Environment(\.matrixService) private var matrixService
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.errorReporter) private var errorReporter
    @State private var moreExpanded = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ServerPickerHeader()

                VStack(spacing: 0) {
                    ForEach(HomeServer.primary) { server in
                        HomeServerRow(server: server, oauthAction: { logInWithBrowser(server: server) })

                        if server.id != HomeServer.primary.last?.id {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
                .background(.quinary, in: .rect(cornerRadius: 10))

                DisclosureGroup(isExpanded: $moreExpanded) {
                    VStack(spacing: 0) {
                        ForEach(HomeServer.more) { server in
                            HomeServerRow(server: server, oauthAction: { logInWithBrowser(server: server) })
                        }

                        Divider()
                            .padding(.leading, 52)

                        DirectoryLinkRow()
                    }
                    .background(.quinary, in: .rect(cornerRadius: 10))
                    .padding(.top, 8)
                } label: {
                    Button("More providers") {
                        withAnimation {
                            moreExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.headline)

                Button("I already have an account", action: goToSignIn)
                    .foregroundStyle(.tint)
            }
            .frame(maxWidth: 440)
            .padding(.vertical, 32)
            .padding([.leading, .trailing], 2)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top) {
            BackBar(label: "Welcome") { step = .welcome }
        }
    }

    // MARK: - Actions

    private func logInWithBrowser(server: HomeServer) {
        Task {
            do {
                try await matrixService.startOAuthLogin(
                    homeserver: server.id
                ) { [webAuthenticationSession] url in
                    try await webAuthenticationSession.authenticate(
                        using: url,
                        callbackURLScheme: "io.github.subpop.relay",
                        preferredBrowserSession: .shared
                    )
                }
            } catch let error as ASWebAuthenticationSessionError
                where error.code == .canceledLogin {
                return
            } catch {
                errorReporter.report(.loginFailed(error.localizedDescription))
            }
            if case .error(let msg) = matrixService.authState {
                errorReporter.report(.loginFailed(msg))
            }
        }
    }

    private func goToSignIn() {
        step = .signIn
    }
}

// MARK: - Header

/// The heading and subheading for the server picker.
private struct ServerPickerHeader: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "network")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text("Choose a provider")
                .font(.title2)
                .bold()

            Text(
                "Pick a server to create your account. You can message anyone on Matrix, no matter which provider they use."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding([.leading, .trailing], 52)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Server Row

/// A single homeserver row with an icon, name, description, action button,
/// and a "Learn more" link.
///
/// Servers that support OAuth show a "Sign in with Browser" button that triggers
/// the OAuth flow. Servers that don't support OAuth show a "Sign Up" button that
/// opens the server's web registration page in the browser.
private struct HomeServerRow: View {
    let server: HomeServer
    let oauthAction: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: server.icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.body)
                    .bold()

                Text(server.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if let signUpURL = server.signUpURL {
                    Button("Sign Up", action: { openURL(signUpURL) })
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Sign in with Browser", action: oauthAction)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }

                Button("Learn more", action: { openURL(server.learnMoreURL) })
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Directory Link

/// A row that links to the full homeserver directory.
private struct DirectoryLinkRow: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(action: { openURL(HomeServer.directoryURL) }) {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Browse more servers")
                        .font(.body)
                        .bold()

                    Text("Find more servers at joinmatrix.org.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    ServerPickerPage(step: .constant(.pickServer))
        .frame(width: 700, height: 580)
}
