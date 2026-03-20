import AppKit
import RelayCore
import SwiftUI

struct LoginView: View {
    @Environment(\.matrixService) private var matrixService
    @State private var matrixID = MatrixID()
    @State private var password = ""
    @State private var errorMessage: String?

    var initialError: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    AppIconView(size: 96)
                        .frame(width: 96, height: 96)

                    Text("Relay")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("A friendly Matrix client")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    TextField("@user:homeserver", value: $matrixID, format: MatrixIDFormat())
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(signIn)
                }

                if let error = errorMessage ?? initialError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    Button(action: signIn) {
                        Text("Sign In")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!matrixID.isValid || password.isEmpty)

                    HStack {
                        VStack { Divider() }
                        Text("or")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        VStack { Divider() }
                    }

                    Button(action: signInWithOAuth) {
                        Label("Sign in with OAuth", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(!matrixID.isValid)
                }

                Link(
                    "Don't have a home server? Find one!",
                    destination: URL(string: "https://servers.joinmatrix.org/")!
                )
                .font(.caption)
            }
            .frame(maxWidth: 320)
            .padding(32)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signIn() {
        guard matrixID.isValid, !password.isEmpty else { return }
        errorMessage = nil
        Task {
            await matrixService.login(
                username: matrixID.username,
                password: password,
                homeserver: matrixID.homeserver
            )
            if case .error(let msg) = matrixService.authState {
                errorMessage = msg
            }
        }
    }

    private func signInWithOAuth() {
        guard matrixID.isValid else { return }
        errorMessage = nil
        Task {
            do {
                try await matrixService.startOAuthLogin(homeserver: matrixID.homeserver)
            } catch {
                errorMessage = error.localizedDescription
            }
            if case .error(let msg) = matrixService.authState {
                errorMessage = msg
            }
        }
    }
}

#Preview {
    LoginView()
        .frame(width: 600, height: 500)
}

#Preview("With Error") {
    LoginView(initialError: "Invalid username or password. Please try again.")
        .frame(width: 600, height: 500)
}

private struct AppIconView: NSViewRepresentable {
    let size: CGFloat

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView()
        imageView.image = NSImage(named: NSImage.applicationIconName)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentHuggingPriority(.required, for: .vertical)
        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {}
}

private struct MatrixID: Equatable {
    var username = ""
    var homeserver = ""

    var isValid: Bool {
        !username.isEmpty && !homeserver.isEmpty && homeserver.contains(".")
    }
}

private struct MatrixIDFormat: ParseableFormatStyle {
    var parseStrategy: MatrixIDParseStrategy { MatrixIDParseStrategy() }

    func format(_ value: MatrixID) -> String {
        guard !value.username.isEmpty || !value.homeserver.isEmpty else { return "" }
        return "@\(value.username):\(value.homeserver)"
    }
}

private struct MatrixIDParseStrategy: ParseStrategy {
    func parse(_ value: String) throws -> MatrixID {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return MatrixID() }

        guard trimmed.hasPrefix("@") else {
            throw FormatError.missingPrefix
        }
        let body = trimmed.dropFirst()
        guard let colon = body.firstIndex(of: ":") else {
            throw FormatError.missingColon
        }
        let username = String(body[body.startIndex..<colon])
        let homeserver = String(body[body.index(after: colon)...])
        guard !username.isEmpty else {
            throw FormatError.emptyUsername
        }
        guard !homeserver.isEmpty, homeserver.contains(".") else {
            throw FormatError.invalidHomeserver
        }
        return MatrixID(username: username, homeserver: homeserver)
    }

    private enum FormatError: LocalizedError {
        case missingPrefix, missingColon, emptyUsername, invalidHomeserver

        var errorDescription: String? {
            switch self {
            case .missingPrefix: "Matrix ID must start with @"
            case .missingColon: "Use the format @user:homeserver"
            case .emptyUsername: "Username cannot be empty"
            case .invalidHomeserver: "Invalid homeserver address"
            }
        }
    }
}
