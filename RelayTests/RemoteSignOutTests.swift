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

import MatrixKit
import MatrixKitCrypto
import Testing

@testable import Relay

// MARK: - RemoteSignOutTests

struct RemoteSignOutTests {
    @Test @MainActor func sessionInvalidationMatchesUnknownToken() {
        #expect(RelayClient.isSessionInvalidation(MatrixError.unknownToken(softLogout: nil)))
        #expect(RelayClient.isSessionInvalidation(MatrixError.unknownToken(softLogout: true)))
        #expect(RelayClient.isSessionInvalidation(MatrixError.unknownToken(softLogout: false)))
        #expect(!RelayClient.isSessionInvalidation(MatrixError.notAuthenticated))
        #expect(!RelayClient.isSessionInvalidation(MatrixError.networkError("boom")))
        #expect(
            !RelayClient.isSessionInvalidation(
                MatrixError.serverError(code: "M_FORBIDDEN", message: "no", retryAfter: nil)))
    }

    @Test @MainActor func softLogoutHintSurvives() {
        #expect(RelayClient.softLogoutHint(MatrixError.unknownToken(softLogout: true)) == true)
        #expect(RelayClient.softLogoutHint(MatrixError.unknownToken(softLogout: false)) == false)
        #expect(RelayClient.softLogoutHint(MatrixError.unknownToken(softLogout: nil)) == nil)
        #expect(RelayClient.softLogoutHint(MatrixError.notAuthenticated) == nil)
    }

    @Test @MainActor func handleRemoteSignOutRaisesAlertOnce() {
        let client = RelayClient(keychain: InMemoryKeyStore())
        #expect(!client.remoteSignOutNoticed)
        client.handleRemoteSignOut()
        #expect(client.remoteSignOutNoticed)
        #expect(client.syncState == .idle)
        client.handleRemoteSignOut()
        #expect(client.remoteSignOutNoticed)
        #expect(client.recentActivity.last?.text == "Session signed out remotely")
    }

    @Test @MainActor func logoutClearsSignOutAlert() async {
        let client = RelayClient(keychain: InMemoryKeyStore())
        client.handleRemoteSignOut()
        #expect(client.remoteSignOutNoticed)
        await client.logout()
        #expect(!client.remoteSignOutNoticed)
        #expect(client.authState == .loggedOut)
    }

    @Test @MainActor func signOutRetryWithoutSessionIsNoop() async {
        // The alert-dismissal path must never wipe: with no live client
        // the retry is a no-op (the flag stays armed, auth state untouched).
        let client = RelayClient(keychain: InMemoryKeyStore())
        client.handleRemoteSignOut(source: "test")
        #expect(client.remoteSignOutNoticed)
        await client.retrySessionAfterRemoteSignOut()
        #expect(client.remoteSignOutNoticed)
        #expect(client.authState == .unknown)
    }

    @Test @MainActor func signOutSourceDefaults() {
        let client = RelayClient(keychain: InMemoryKeyStore())
        client.handleRemoteSignOut(softLogout: true)
        #expect(client.remoteSignOutNoticed)
    }
}
