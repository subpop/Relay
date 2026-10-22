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
import MatrixKit
import Testing

@testable import Relay

// MARK: - KeyBackupPresentationTests

struct KeyBackupPresentationTests {

    private func present(
        _ status: KeyBackupStatus?, verified: Bool = true
    ) -> KeyBackupPresentation {
        KeyBackupPresentation(status: status, isSessionVerified: verified)
    }

    @Test func unknownStatusWarnsAndOffersNothing() {
        let presentation = present(nil)
        #expect(presentation.tone == .warning)
        #expect(!presentation.canBackUpNow)
        #expect(!presentation.canRestore)
    }

    @Test func missingBackupWarnsAndOffersSetUp() {
        let presentation = present(KeyBackupStatus())
        #expect(presentation.tone == .warning)
        #expect(presentation.canSetUp)
        #expect(!presentation.canBackUpNow)
        #expect(!presentation.canRestore)
    }

    @Test func onlyAMissingBackupCanBeSetUp() {
        #expect(!present(nil).canSetUp)
        #expect(!present(KeyBackupStatus(exists: true, isTrusted: false)).canSetUp)
        #expect(!present(KeyBackupStatus(exists: true, isTrusted: true)).canSetUp)
    }

    @Test func untrustedBackupCanBeRestoredButNotUploadedTo() {
        let status = KeyBackupStatus(exists: true, isTrusted: false, pendingSessions: 4)
        let presentation = present(status)
        #expect(presentation.tone == .warning)
        #expect(!presentation.canBackUpNow)
        #expect(presentation.canRestore)
    }

    @Test func untrustedBackupExplanationDependsOnVerification() {
        let status = KeyBackupStatus(exists: true, isTrusted: false)
        #expect(present(status, verified: false).detail != present(status, verified: true).detail)
    }

    @Test func trustedBackupWithPendingKeysOffersBackUpNow() {
        let status = KeyBackupStatus(
            exists: true, isTrusted: true, backedUpSessions: 12, pendingSessions: 3)
        let presentation = present(status)
        #expect(presentation.tone == .good)
        #expect(presentation.canBackUpNow)
        #expect(presentation.canRestore)
        #expect(presentation.detail.contains("12"))
        #expect(presentation.detail.contains("3"))
    }

    @Test func trustedBackupWithNothingPendingHasNothingToUpload() {
        let status = KeyBackupStatus(exists: true, isTrusted: true, backedUpSessions: 5)
        let presentation = present(status)
        #expect(presentation.tone == .good)
        #expect(!presentation.canBackUpNow)
        #expect(presentation.canRestore)
    }

    @Test func unattributedKeysAreMentionedOnlyWhenPresent() {
        let without = present(KeyBackupStatus(exists: true, isTrusted: true))
        let with = present(KeyBackupStatus(
            exists: true, isTrusted: true, unattributedSessions: 7))
        #expect(with.detail.contains("7"))
        #expect(with.detail.count > without.detail.count)
    }
}
