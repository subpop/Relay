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

// MARK: - KeyBackupSetupViewModelTests

@MainActor
struct KeyBackupSetupViewModelTests {

    private static func backup(elsewhere: Bool = false) -> NewKeyBackup {
        NewKeyBackup(
            version: "1", recoveryKey: "EsTa 1b2c", storedInSecretStorage: elsewhere)
    }

    private struct SetupFailure: LocalizedError {
        var errorDescription: String? { "Server said no" }
    }

    @Test func creatingShowsTheRecoveryKey() async {
        let model = KeyBackupSetupViewModel(create: { Self.backup() }, copy: { _ in })
        #expect(model.state == .intro)
        await model.createBackup()
        #expect(model.state == .created(recoveryKey: "EsTa 1b2c", usableElsewhere: false))
        #expect(model.recoveryKey == "EsTa 1b2c")
    }

    @Test func secretStorageMakesTheKeyUsableElsewhere() async {
        let model = KeyBackupSetupViewModel(
            create: { Self.backup(elsewhere: true) }, copy: { _ in })
        await model.createBackup()
        #expect(model.state == .created(recoveryKey: "EsTa 1b2c", usableElsewhere: true))
    }

    @Test func theSheetCannotCloseUntilTheKeyIsSaved() async {
        let model = KeyBackupSetupViewModel(create: { Self.backup() }, copy: { _ in })
        #expect(model.canFinish)
        await model.createBackup()
        #expect(!model.canFinish)
        model.hasSavedRecoveryKey = true
        #expect(model.canFinish)
    }

    @Test func aFailureCanBeRetried() async {
        var attempts = 0
        let model = KeyBackupSetupViewModel(
            create: {
                attempts += 1
                if attempts == 1 { throw SetupFailure() }
                return Self.backup()
            },
            copy: { _ in })
        await model.createBackup()
        #expect(model.state == .failed("Server said no"))
        #expect(model.canFinish)
        await model.createBackup()
        #expect(model.recoveryKey == "EsTa 1b2c")
        #expect(attempts == 2)
    }

    @Test func aCreatedBackupIsNeverCreatedTwice() async {
        var attempts = 0
        let model = KeyBackupSetupViewModel(
            create: {
                attempts += 1
                return Self.backup()
            },
            copy: { _ in })
        await model.createBackup()
        await model.createBackup()
        #expect(attempts == 1)
        #expect(model.recoveryKey == "EsTa 1b2c")
    }

    @Test func copyingNeedsAKey() async {
        var copied: [String] = []
        let model = KeyBackupSetupViewModel(
            create: { Self.backup() }, copy: { copied.append($0) })
        model.copyRecoveryKey()
        #expect(copied.isEmpty)
        #expect(!model.didCopyRecoveryKey)
        await model.createBackup()
        model.copyRecoveryKey()
        #expect(copied == ["EsTa 1b2c"])
        #expect(model.didCopyRecoveryKey)
    }
}
