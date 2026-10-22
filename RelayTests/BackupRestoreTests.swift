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
import MatrixKitCrypto
import Testing

@testable import Relay

// MARK: - BackupRestoreTests

@MainActor
struct BackupRestoreTests {

    @Test func loggedOutClientHoldsNoBackupKey() async {
        let client = RelayClient(keychain: InMemoryKeyStore())
        #expect(await client.storedBackupKey() == nil)
    }

    @Test func restoreWithoutBackupReportsInsteadOfStarting() async {
        let client = RelayClient(keychain: InMemoryKeyStore())
        client.startBackupRestore()
        for _ in 0..<1_000 where client.errorReporter.currentError == nil {
            await Task.yield()
        }
        guard case .keyBackupRestoreFailed = client.errorReporter.currentError else {
            Issue.record("expected a restore failure, got \(String(describing: client.errorReporter.currentError))")
            return
        }
        #expect(client.keyFetch.isRestoring == false)
    }
}
