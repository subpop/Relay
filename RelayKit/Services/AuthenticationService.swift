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

import AppKit
import AuthenticationServices
import Foundation
import RelayInterface
import os

private let logger = Logger(subsystem: "RelayKit", category: "Authentication")

/// Handles Matrix authentication: password login, OAuth/OIDC, session restore, and logout.
///
/// ``AuthenticationService`` encapsulates all authentication-related logic, including
/// building SDK clients, managing keychain-persisted sessions, and coordinating OAuth
/// browser flows. It produces an authenticated `Client` that the caller (``MatrixService``)
/// retains for further operations.
@MainActor
final class AuthenticationService {

    // MARK: - Persistence Model

    struct StoredSession: Codable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var userId: String
        var deviceId: String
        var homeserverUrl: String
        var oidcData: String?
    }

    // MARK: - Data Paths

    static var dataDirectory: URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Relay/matrix-data", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var cacheDirectory: URL {
        let url = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Relay/matrix-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func resetLocalSessionData() {
        let fm = FileManager.default
        try? fm.removeItem(at: dataDirectory)
        try? fm.removeItem(at: cacheDirectory)
    }

    private let sessionDelegate = KeychainSessionDelegate()

    // MARK: - Session Restore

    /// Attempts to restore a previously saved session from the keychain.
    ///
    /// - Returns: A tuple of the authenticated `Client` and user ID, or `nil` if no valid
    ///   session was found.
    func restoreSession() async -> (Client, String)? {
        guard let data = KeychainService.load(),
              let stored = try? JSONDecoder().decode(StoredSession.self, from: data)
        else {
            return nil
        }

        do {
            let builder = ClientBuilder()
                .homeserverUrl(url: stored.homeserverUrl)
                .sessionPaths(
                    dataPath: Self.dataDirectory.path,
                    cachePath: Self.cacheDirectory.path
                )
                .slidingSyncVersionBuilder(versionBuilder: .discoverNative)

            let client = try await builder.build()

            let session = Session(
                accessToken: stored.accessToken,
                refreshToken: stored.refreshToken,
                userId: stored.userId,
                deviceId: stored.deviceId,
                homeserverUrl: stored.homeserverUrl,
                oidcData: stored.oidcData,
                slidingSyncVersion: .native
            )
            try await client.restoreSession(session: session)

            return (client, stored.userId)
        } catch {
            logger.error("Session restore failed: \(error)")
            return nil
        }
    }

    // MARK: - Password Login

    /// Authenticates with the homeserver using a username and password.
    ///
    /// - Parameters:
    ///   - username: The Matrix username.
    ///   - password: The account password.
    ///   - homeserver: The homeserver URL or server name.
    /// - Returns: The authenticated `Client` and the user's Matrix ID.
    func login(username: String, password: String, homeserver: String) async throws -> (Client, String) {
        Self.resetLocalSessionData()

        let builder = ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: homeserver)
            .sessionPaths(
                dataPath: Self.dataDirectory.path,
                cachePath: Self.cacheDirectory.path
            )
            .slidingSyncVersionBuilder(versionBuilder: .discoverNative)

        let client = try await builder.build()

        try await client.login(
            username: username,
            password: password,
            initialDeviceName: "Relay",
            deviceId: nil
        )

        let session = try client.session()
        saveSession(session)

        return (client, session.userId)
    }

    // MARK: - OAuth Login

    private static let oauthRedirectScheme = "com.github.subpop.relay"
    private static let oauthRedirectURI = "\(oauthRedirectScheme):/"

    /// Initiates an OAuth/OIDC login flow via the system browser.
    ///
    /// - Parameter homeserver: The homeserver URL or server name.
    /// - Returns: The authenticated `Client` and the user's Matrix ID.
    /// - Throws: If the homeserver doesn't support OIDC, the browser flow fails, or the
    ///   user cancels.
    func startOAuthLogin(homeserver: String) async throws -> (Client, String) {
        Self.resetLocalSessionData()

        let builder = ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: homeserver)
            .sessionPaths(
                dataPath: Self.dataDirectory.path,
                cachePath: Self.cacheDirectory.path
            )
            .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
            .setSessionDelegate(sessionDelegate: sessionDelegate)

        let client = try await builder.build()

        let loginDetails = await client.homeserverLoginDetails()
        guard loginDetails.supportsOidcLogin() else {
            throw OAuthError.notSupported
        }

        let oidcConfig = OidcConfiguration(
            clientName: "Relay",
            redirectUri: Self.oauthRedirectURI,
            clientUri: "https://github.com/subpop/Relay",
            logoUri: nil,
            tosUri: nil,
            policyUri: nil,
            staticRegistrations: [:]
        )

        let authData = try await client.urlForOidc(
            oidcConfiguration: oidcConfig,
            prompt: nil,
            loginHint: nil,
            deviceId: nil,
            additionalScopes: nil
        )

        let loginURL = authData.loginUrl()
        guard let url = URL(string: loginURL) else {
            throw OAuthError.invalidURL
        }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.oauthRedirectScheme
            ) { @Sendable callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: OAuthError.missingCallback)
                }
            }
            session.presentationContextProvider = OAuthPresentationContext.shared
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }

        try await client.loginWithOidcCallback(callbackUrl: callbackURL.absoluteString)

        let session = try client.session()
        saveSession(session)

        return (client, session.userId)
    }

    /// Clears the persisted session and local SDK data.
    func clearSession() {
        KeychainService.delete()
        Self.resetLocalSessionData()
    }

    // MARK: - Private

    private func saveSession(_ session: Session) {
        let stored = StoredSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            deviceId: session.deviceId,
            homeserverUrl: session.homeserverUrl,
            oidcData: session.oidcData
        )
        if let encoded = try? JSONEncoder().encode(stored) {
            KeychainService.save(encoded)
        }
    }
}

// MARK: - OIDC Session Delegate

final class KeychainSessionDelegate: ClientSessionDelegate, Sendable {
    private struct StoredSession: Codable {
        var accessToken: String
        var refreshToken: String?
        var userId: String
        var deviceId: String
        var homeserverUrl: String
        var oidcData: String?
    }

    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        guard let data = KeychainService.load(),
              let stored = try? JSONDecoder().decode(StoredSession.self, from: data),
              stored.userId == userId
        else {
            throw KeychainSessionError.sessionNotFound
        }
        return Session(
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            userId: stored.userId,
            deviceId: stored.deviceId,
            homeserverUrl: stored.homeserverUrl,
            oidcData: stored.oidcData,
            slidingSyncVersion: .native
        )
    }

    func saveSessionInKeychain(session: Session) {
        let stored = StoredSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            deviceId: session.deviceId,
            homeserverUrl: session.homeserverUrl,
            oidcData: session.oidcData
        )
        if let data = try? JSONEncoder().encode(stored) {
            KeychainService.save(data)
        }
    }
}

enum KeychainSessionError: Error {
    case sessionNotFound
}

enum OAuthError: LocalizedError {
    case missingCallback
    case notSupported
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .missingCallback: "No callback URL received from authentication."
        case .notSupported: "This homeserver does not support OAuth login."
        case .invalidURL: "Invalid OAuth login URL."
        }
    }
}

private class OAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthPresentationContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
    }
}
