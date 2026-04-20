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

import Foundation
import RelayInterface
import os

private let logger = Logger(subsystem: "RelayKit", category: "Authentication")

/// The persisted representation of a Matrix session, stored in the keychain.
///
/// Both ``AuthenticationService`` and ``KeychainSessionDelegate`` use this type
/// to encode/decode session data, ensuring a single source of truth.
///
/// Marked `nonisolated` so that `Codable` conformance can be used from any
/// isolation context (e.g. the nonisolated ``KeychainSessionDelegate``).
nonisolated struct StoredSession: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var userId: String
    var deviceId: String
    var homeserverUrl: String
    var oidcData: String?
}

/// Handles Matrix authentication: password login, OAuth/OIDC, session restore, and logout.
///
/// ``AuthenticationService`` encapsulates all authentication-related logic, including
/// building SDK clients via ``ClientBuilderProxy``, managing keychain-persisted sessions,
/// and coordinating OAuth browser flows. It produces an authenticated ``ClientProxy`` that
/// the caller (``MatrixService``) retains for further operations.
///
/// The OAuth browser flow is decoupled from this service: callers provide an `openURL`
/// closure that opens the authorization URL and returns the callback URL. This allows
/// SwiftUI views to use `@Environment(\.webAuthenticationSession)` without coupling
/// the service to AppKit or AuthenticationServices.
@MainActor
final class AuthenticationService {

    // MARK: - Data Paths

    static var dataDirectory: URL {
        #if DEBUG
        let subdirectory = "Relay/matrix-data-debug"
        #else
        let subdirectory = "Relay/matrix-data"
        #endif

        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(subdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var cacheDirectory: URL {
        #if DEBUG
        let subdirectory = "Relay/matrix-cache-debug"
        #else
        let subdirectory = "Relay/matrix-cache"
        #endif

        let url = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(subdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func resetLocalSessionData() {
        // swiftlint:disable:next identifier_name
        let fm = FileManager.default
        try? fm.removeItem(at: dataDirectory)
        try? fm.removeItem(at: cacheDirectory)
    }

    /// The active session delegate, scoped to the current client lifecycle.
    ///
    /// A new delegate is created for each login/restore so that stale
    /// callbacks from a previous SDK client cannot overwrite the new
    /// session's tokens in the keychain.
    private var sessionDelegate = KeychainSessionDelegate()

    // MARK: - Builder Helpers

    /// Creates a ``ClientBuilderProxy`` with common configuration applied.
    private func makeBuilder() -> ClientBuilderProxy {
        // Invalidate the previous delegate so any lingering SDK callbacks
        // from an old client are silently dropped.
        sessionDelegate.invalidate()
        sessionDelegate = KeychainSessionDelegate()

        return ClientBuilderProxy()
            .sessionPaths(
                dataPath: Self.dataDirectory.path,
                cachePath: Self.cacheDirectory.path
            )
            .slidingSyncVersionBuilder(.discoverNative)
            .autoEnableCrossSigning(true)
            .autoEnableBackups(true)
            .userAgent("Relay")
            .setSessionDelegate(sessionDelegate)
    }

    // MARK: - Session Restore

    /// Attempts to restore a previously saved session from the keychain.
    ///
    /// - Returns: A tuple of the authenticated ``ClientProxy`` and user ID, or `nil` if no
    ///   valid session was found.
    func restoreSession() async -> (ClientProxy, String)? {
        guard let data = KeychainService.load(),
              let stored = try? JSONDecoder().decode(StoredSession.self, from: data)
        else {
            return nil
        }

        do {
            let tokenPrefix = String(stored.accessToken.prefix(8))
            // swiftlint:disable:next line_length
            logger.debug("Restoring session: userId=\(stored.userId), tokenPrefix=\(tokenPrefix)..., hasRefreshToken=\(stored.refreshToken != nil), hasOidcData=\(stored.oidcData != nil)")

            let client = try await makeBuilder()
                .serverNameOrHomeserverUrl(stored.homeserverUrl)
                .buildClient()

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

            logger.debug("Session restored successfully for \(stored.userId)")
            let clientProxy = try ClientProxy(client: client)
            return (clientProxy, stored.userId)
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
    /// - Returns: The authenticated ``ClientProxy`` and the user's Matrix ID.
    func login(username: String, password: String, homeserver: String) async throws -> (ClientProxy, String) {
        Self.resetLocalSessionData()

        let client = try await makeBuilder()
            .serverNameOrHomeserverUrl(homeserver)
            .buildClient()

        try await client.login(
            username: username,
            password: password,
            initialDeviceName: "Relay",
            deviceId: nil
        )

        let session = try client.session()
        saveSession(session)

        let clientProxy = try ClientProxy(client: client)
        return (clientProxy, session.userId)
    }

    // MARK: - OAuth Login

    static let oauthRedirectScheme = "io.github.subpop.relay"
    private static let oauthRedirectURI = "\(oauthRedirectScheme):/"

    /// Initiates an OAuth/OIDC login flow, using the provided closure to open the browser.
    ///
    /// The `openURL` closure receives the OIDC authorization URL and must return the
    /// callback URL after the user completes authentication. Callers typically implement
    /// this using SwiftUI's `WebAuthenticationSession` environment value.
    ///
    /// - Parameters:
    ///   - homeserver: The homeserver URL or server name.
    ///   - openURL: A closure that opens the authorization URL in a browser and returns
    ///     the callback URL.
    /// - Returns: The authenticated ``ClientProxy`` and the user's Matrix ID.
    /// - Throws: If the homeserver doesn't support OIDC, the browser flow fails, or the
    ///   user cancels.
    func startOAuthLogin(
        homeserver: String,
        openURL: @escaping @concurrent @Sendable (URL) async throws -> URL
    ) async throws -> (ClientProxy, String) {
        Self.resetLocalSessionData()

        let client = try await makeBuilder()
            .serverNameOrHomeserverUrl(homeserver)
            .buildClient()

        let loginDetails = await client.homeserverLoginDetails()
        guard loginDetails.supportsOidcLogin() else {
            throw RelayError.oauthNotSupported
        }

        let oidcConfig = OidcConfiguration(
            clientName: "Relay",
            redirectUri: Self.oauthRedirectURI,
            clientUri: "https://subpop.github.io/Relay",
            logoUri: "https://subpop.github.io/Relay/logo-256.png",
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
            throw RelayError.oauthInvalidURL
        }

        let callbackURL = try await openURL(url)

        try await client.loginWithOidcCallback(callbackUrl: callbackURL.absoluteString)

        let session = try client.session()
        saveSession(session)

        let clientProxy = try ClientProxy(client: client)
        return (clientProxy, session.userId)
    }

    /// Clears the persisted session and local SDK data.
    ///
    /// Also invalidates the current session delegate so any lingering
    /// SDK callbacks from the old client cannot write stale tokens.
    func clearSession() {
        sessionDelegate.invalidate()
        KeychainService.delete()
        Self.resetLocalSessionData()
    }

    // MARK: - Private

    private func saveSession(_ session: Session) {
        // swiftlint:disable:next line_length
        logger.debug("Saving session: userId=\(session.userId), hasRefreshToken=\(session.refreshToken != nil), hasOidcData=\(session.oidcData != nil)")
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

final class KeychainSessionDelegate: ClientSessionDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "RelayKit", category: "KeychainSessionDelegate")

    /// Guards against stale callbacks from a previous SDK client.
    ///
    /// When `AuthenticationService` creates a new client (e.g. on re-login),
    /// it invalidates the previous delegate so that any lingering token-refresh
    /// callbacks from the old Rust SDK client are silently dropped instead of
    /// overwriting the new session's tokens in the keychain.
    private var isValid = true

    /// Marks this delegate as invalid so all future callbacks are ignored.
    func invalidate() {
        isValid = false
    }

    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        guard isValid else {
            Self.logger.warning("retrieveSessionFromKeychain: delegate invalidated, ignoring")
            throw KeychainSessionError.sessionNotFound
        }
        Self.logger.debug("retrieveSessionFromKeychain called for user: \(userId)")
        guard let data = KeychainService.load() else {
            Self.logger.error("No session data found in keychain")
            throw KeychainSessionError.sessionNotFound
        }
        guard let stored = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            Self.logger.error("Failed to decode stored session data")
            throw KeychainSessionError.sessionNotFound
        }
        guard stored.userId == userId else {
            Self.logger.error("Stored userId \(stored.userId) does not match requested \(userId)")
            throw KeychainSessionError.sessionNotFound
        }
        // swiftlint:disable:next line_length
        Self.logger.debug("Session retrieved: hasRefreshToken=\(stored.refreshToken != nil), hasOidcData=\(stored.oidcData != nil)")
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
        guard isValid else {
            Self.logger.warning("saveSessionInKeychain: delegate invalidated, ignoring")
            return
        }
        let tokenPrefix = String(session.accessToken.prefix(8))
        // swiftlint:disable:next line_length
        Self.logger.debug("saveSessionInKeychain called for user: \(session.userId), tokenPrefix=\(tokenPrefix)..., hasRefreshToken=\(session.refreshToken != nil), hasOidcData=\(session.oidcData != nil)")
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
            Self.logger.debug("Session saved to keychain")
        } else {
            Self.logger.error("Failed to encode session for keychain storage")
        }
    }
}

enum KeychainSessionError: Error {
    case sessionNotFound
}
