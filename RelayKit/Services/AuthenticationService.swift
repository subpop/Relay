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
    var oauthData: String?
}

/// Outcome of an attempt to restore a previously saved session.
///
/// Distinguishes "no keychain session at all" (→ login screen) from
/// "session exists but we couldn't reach the homeserver" (→ restore
/// the user into a cache-only experience and retry once connectivity
/// returns).
enum RestoreOutcome {
    /// No saved session in the keychain. Caller should show login.
    case noSavedSession
    /// Session restored successfully and is ready for sync.
    case restored(ClientProxy, userId: String)
    /// A session is saved but the homeserver couldn't be reached
    /// (no network, well-known discovery failed, connection timed out).
    /// Caller should treat the user as logged-in but with sync stuck
    /// offline, and retry the full restore when connectivity returns.
    case offlineWithSavedSession(userId: String, homeserverUrl: String)
    /// A session is saved but restore failed for a non-network reason
    /// (auth invalidated, schema mismatch, etc.). Caller should show
    /// an error.
    case failed(Error)
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

    private let networkMonitor: NetworkMonitor
    var activityLog: ActivityLog?

    init(networkMonitor: NetworkMonitor) {
        self.networkMonitor = networkMonitor
    }

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

    /// Deletes only the rebuildable cache directory (sync state, timeline events),
    /// preserving the data directory (crypto store, device identity).
    static func resetCacheData() {
        try? FileManager.default.removeItem(at: cacheDirectory)
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
        sessionDelegate.activityLog = activityLog

        return ClientBuilderProxy()
            .sessionPaths(
                dataPath: Self.dataDirectory.path,
                cachePath: Self.cacheDirectory.path,
                // The SDK default is four connections per physical CPU for each store,
                // which can exhaust macOS file descriptors on high-core-count systems.
                poolMaxSize: 4
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
    /// Distinguishes "no saved session" from "homeserver couldn't be
    /// reached" so the caller (``MatrixService``) can choose between
    /// going to the login screen and entering an offline-restored
    /// cache-only state. See ``RestoreOutcome``.
    func restoreSession() async -> RestoreOutcome {
        guard let data = KeychainService.load(),
              let stored = try? JSONDecoder().decode(StoredSession.self, from: data)
        else {
            activityLog?.log(
                category: .auth, severity: .info, source: "AuthenticationService",
                summary: "No saved session in keychain"
            )
            return .noSavedSession
        }

        // If the radio is off, don't even try `buildClient()` — well-known
        // discovery would just fail. Skip straight to offline-restore so
        // the user sees their cached data instead of the login screen.
        guard networkMonitor.isConnected else {
            activityLog?.log(
                category: .auth, severity: .info, source: "AuthenticationService",
                summary: "Restoring session offline",
                metadata: ["userId": stored.userId]
            )
            return .offlineWithSavedSession(
                userId: stored.userId,
                homeserverUrl: stored.homeserverUrl
            )
        }

        do {
            activityLog?.log(
                category: .auth, severity: .debug, source: "AuthenticationService",
                summary: "Restoring session",
                metadata: ["userId": stored.userId]
            )

            let client = try await makeBuilder()
                .serverNameOrHomeserverUrl(stored.homeserverUrl)
                .buildClient()

            let session = Session(
                accessToken: stored.accessToken,
                refreshToken: stored.refreshToken,
                userId: stored.userId,
                deviceId: stored.deviceId,
                homeserverUrl: stored.homeserverUrl,
                oauthData: stored.oauthData,
                slidingSyncVersion: .native
            )
            try await client.restoreSession(session: session)

            let clientProxy = try ClientProxy(client: client)
            activityLog?.log(
                category: .auth, severity: .info, source: "AuthenticationService",
                summary: "Session restored from keychain",
                metadata: ["userId": stored.userId]
            )
            return .restored(clientProxy, userId: stored.userId)
        } catch {
            if NetworkErrorClassifier.isOfflineShaped(error) {
                activityLog?.log(
                    category: .auth, severity: .warning, source: "AuthenticationService",
                    summary: "Session restore deferred — homeserver unreachable",
                    detail: error.localizedDescription
                )
                return .offlineWithSavedSession(
                    userId: stored.userId,
                    homeserverUrl: stored.homeserverUrl
                )
            }
            activityLog?.log(
                category: .auth, severity: .error, source: "AuthenticationService",
                summary: "Session restore failed",
                detail: error.localizedDescription
            )
            return .failed(error)
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
        activityLog?.log(
            category: .auth, severity: .info, source: "AuthenticationService",
            summary: "Password login succeeded",
            metadata: ["userId": session.userId]
        )
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
        guard loginDetails.supportsOauthLogin() else {
            activityLog?.log(
                category: .auth, severity: .warning, source: "AuthenticationService",
                summary: "Homeserver does not support OIDC",
                metadata: ["homeserver": homeserver]
            )
            throw RelayError.oauthNotSupported
        }

        let oauthConfig = OAuthConfiguration(
            clientName: "Relay",
            redirectUri: Self.oauthRedirectURI,
            clientUri: "https://subpop.github.io/Relay",
            logoUri: "https://subpop.github.io/Relay/logo-256.png",
            tosUri: nil,
            policyUri: nil,
            staticRegistrations: [:]
        )

        let authData = try await client.urlForOauth(
            oauthConfiguration: oauthConfig,
            prompt: nil,
            loginHint: nil,
            deviceId: nil,
            additionalScopes: nil
        )

        let loginURL = authData.loginUrl()
        guard let url = URL(string: loginURL) else {
            throw RelayError.oauthInvalidURL
        }

        activityLog?.log(
            category: .auth, severity: .info, source: "AuthenticationService",
            summary: "OAuth login flow started"
        )

        let callbackURL = try await openURL(url)

        try await client.loginWithOauthCallback(callbackUrl: callbackURL.absoluteString)

        let session = try client.session()
        saveSession(session)

        let clientProxy = try ClientProxy(client: client)
        activityLog?.log(
            category: .auth, severity: .info, source: "AuthenticationService",
            summary: "OAuth login succeeded",
            metadata: ["userId": session.userId]
        )
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
        activityLog?.log(
            category: .auth, severity: .info, source: "AuthenticationService",
            summary: "Session cleared"
        )
    }

    // MARK: - Private

    private func saveSession(_ session: Session) {
        let stored = StoredSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            deviceId: session.deviceId,
            homeserverUrl: session.homeserverUrl,
            oauthData: session.oauthData
        )
        if let encoded = try? JSONEncoder().encode(stored) {
            KeychainService.save(encoded)
            activityLog?.log(
                category: .auth, severity: .debug, source: "AuthenticationService",
                summary: "Session saved to keychain"
            )
        } else {
            activityLog?.log(
                category: .auth, severity: .warning, source: "AuthenticationService",
                summary: "Failed to encode session for keychain"
            )
        }
    }
}

// MARK: - OIDC Session Delegate

final class KeychainSessionDelegate: ClientSessionDelegate, @unchecked Sendable {
    /// Guards against stale callbacks from a previous SDK client.
    ///
    /// When `AuthenticationService` creates a new client (e.g. on re-login),
    /// it invalidates the previous delegate so that any lingering token-refresh
    /// callbacks from the old Rust SDK client are silently dropped instead of
    /// overwriting the new session's tokens in the keychain.
    private var isValid = true

    /// Activity log reference for reporting keychain operations.
    ///
    /// Set by ``AuthenticationService/makeBuilder()`` when creating a new delegate.
    /// Because this class is `nonisolated`, all activity log calls dispatch
    /// to `@MainActor`.
    weak var activityLog: ActivityLog?

    /// Marks this delegate as invalid so all future callbacks are ignored.
    func invalidate() {
        isValid = false
    }

    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        guard isValid else {
            Task { @MainActor [activityLog] in
                activityLog?.log(
                    category: .auth, severity: .debug, source: "KeychainSessionDelegate",
                    summary: "Stale session retrieve callback ignored"
                )
            }
            throw KeychainSessionError.sessionNotFound
        }
        guard let data = KeychainService.load() else {
            Task { @MainActor [activityLog] in
                activityLog?.log(
                    category: .auth, severity: .warning, source: "KeychainSessionDelegate",
                    summary: "Keychain load returned no data"
                )
            }
            throw KeychainSessionError.sessionNotFound
        }
        guard let stored = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            Task { @MainActor [activityLog] in
                activityLog?.log(
                    category: .auth, severity: .error, source: "KeychainSessionDelegate",
                    summary: "Failed to decode session from keychain"
                )
            }
            throw KeychainSessionError.sessionNotFound
        }
        guard stored.userId == userId else {
            Task { @MainActor [activityLog] in
                activityLog?.log(
                    category: .auth, severity: .error, source: "KeychainSessionDelegate",
                    summary: "Keychain userId mismatch",
                    metadata: ["expected": userId, "actual": stored.userId]
                )
            }
            throw KeychainSessionError.sessionNotFound
        }
        return Session(
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            userId: stored.userId,
            deviceId: stored.deviceId,
            homeserverUrl: stored.homeserverUrl,
            oauthData: stored.oauthData,
            slidingSyncVersion: .native
        )
    }

    func saveSessionInKeychain(session: Session) {
        guard isValid else {
            Task { @MainActor [activityLog] in
                activityLog?.log(
                    category: .auth, severity: .debug, source: "KeychainSessionDelegate",
                    summary: "Stale session save callback ignored"
                )
            }
            return
        }
        let stored = StoredSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            deviceId: session.deviceId,
            homeserverUrl: session.homeserverUrl,
            oauthData: session.oauthData
        )
        if let data = try? JSONEncoder().encode(stored) {
            KeychainService.save(data)
            Task { @MainActor [activityLog] in
                activityLog?.log(
                    category: .auth, severity: .debug, source: "KeychainSessionDelegate",
                    summary: "Token refresh saved to keychain"
                )
            }
        } else {
            Task { @MainActor [activityLog] in
                activityLog?.log(
                    category: .auth, severity: .error, source: "KeychainSessionDelegate",
                    summary: "Failed to encode refreshed session"
                )
            }
        }
    }
}

enum KeychainSessionError: Error {
    case sessionNotFound
}
