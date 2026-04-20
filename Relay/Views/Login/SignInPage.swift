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

/// The sign-in page for users who already have a Matrix account.
///
/// Supports both password login (via Matrix ID and password) and OAuth/OIDC
/// login. This view preserves the original authentication logic from the
/// previous login form.
struct SignInPage: View {
    @Binding var step: LoginStep
    @Environment(\.matrixService) private var matrixService
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.errorReporter) private var errorReporter
    @State private var matrixID = MatrixID()
    @State private var matrixIDText = ""
    @State private var matrixIDError: String?
    @FocusState private var matrixIDFieldFocused: Bool
    @State private var password = ""
    #if DEBUG
    @State private var customHomeserver = ""
    #endif

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                SignInHeader()

                VStack(spacing: 12) {
                    MatrixIDField(
                        text: $matrixIDText,
                        error: matrixIDError,
                        isFocused: $matrixIDFieldFocused
                    )
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(signIn)
                    #if DEBUG
                    TextField("Homeserver URL (optional)", text: $customHomeserver)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                    #endif
                }
                .onChange(of: matrixIDFieldFocused) { _, focused in
                    if !focused {
                        validateMatrixID()
                    }
                }
                .onChange(of: matrixIDText) {
                    if matrixIDError != nil {
                        matrixIDError = nil
                    }
                }

                VStack(spacing: 10) {
                    Button(action: signIn) {
                        Text("Sign in")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!matrixID.isValid || password.isEmpty)

                    OrDivider()

                    Button(action: signInWithOAuth) {
                        Label("Sign in with Browser", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(!matrixID.isValid)
                }

                Button("Don't have an account? Get started", action: goToPickServer)
            }
            .frame(maxWidth: 320)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top) {
            BackBar(label: "Welcome") { step = .welcome }
        }
    }

    // MARK: - Validation

    private func validateMatrixID() {
        let strategy = MatrixIDParseStrategy()
        do {
            matrixID = try strategy.parse(matrixIDText)
            matrixIDText = MatrixIDFormat().format(matrixID)
            matrixIDError = nil
        } catch {
            matrixID = MatrixID()
            matrixIDError = error.localizedDescription
        }
    }

    // MARK: - Actions

    private var effectiveHomeserver: String {
        #if DEBUG
        let trimmed = customHomeserver.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? matrixID.homeserver : trimmed
        #else
        return matrixID.homeserver
        #endif
    }

    private func signIn() {
        guard matrixID.isValid, !password.isEmpty else { return }
        Task {
            await matrixService.login(
                username: matrixID.username,
                password: password,
                homeserver: effectiveHomeserver
            )
            if case .error(let msg) = matrixService.authState {
                errorReporter.report(.loginFailed(msg))
            }
        }
    }

    private func signInWithOAuth() {
        guard matrixID.isValid else { return }
        Task {
            do {
                try await matrixService.startOAuthLogin(
                    homeserver: effectiveHomeserver
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

    private func goToPickServer() {
        step = .pickServer
    }
}

// MARK: - Header

/// The heading and subheading for the sign-in form.
private struct SignInHeader: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text("Sign in to your account")
                .font(.title2)
                .bold()

            Text("Enter your full Matrix ID to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Matrix ID Field

/// A text field for entering a Matrix ID with inline validation error display.
private struct MatrixIDField: View {
    @Binding var text: String
    var error: String?
    var isFocused: FocusState<Bool>.Binding
    @State private var showingError = false

    var body: some View {
        TextField("@user:home.server", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused(isFocused)
            .autocorrectionDisabled()
            .overlay(alignment: .trailing) {
                if let error {
                    Button("Matrix ID Error", systemImage: "exclamationmark.circle.fill") {
                        showingError.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.red)
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingError, arrowEdge: .trailing) {
                        Text(error)
                            .font(.callout)
                            .padding()
                    }
                    .padding(.trailing, 6)
                }
            }
    }
}

// MARK: - Or Divider

/// A horizontal divider with "or" text in the center.
private struct OrDivider: View {
    var body: some View {
        HStack {
            VStack { Divider() }
            Text("or")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack { Divider() }
        }
    }
}

// MARK: - Preview

#Preview {
    SignInPage(step: .constant(.signIn))
        .frame(width: 700, height: 580)
}
