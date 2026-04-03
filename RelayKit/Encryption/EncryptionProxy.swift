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

// EncryptionProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Observation

/// An `@Observable` proxy that wraps the Matrix SDK `Encryption`.
///
/// Provides reactive backup, recovery, and verification state updates.
/// All state properties update automatically from SDK listener callbacks.
@Observable
public final class EncryptionProxy: EncryptionProxyProtocol, @unchecked Sendable {
    private let encryption: Encryption
    @ObservationIgnored nonisolated(unsafe) private var backupTaskHandle: TaskHandle?
    @ObservationIgnored nonisolated(unsafe) private var recoveryTaskHandle: TaskHandle?
    @ObservationIgnored nonisolated(unsafe) private var verificationTaskHandle: TaskHandle?

    // MARK: - Observable Properties

    /// The current key backup state.
    public private(set) var backupState: BackupState

    /// The current recovery state.
    public private(set) var recoveryState: RecoveryState

    /// The current session verification state.
    public private(set) var verificationState: VerificationState

    // MARK: - Async Streams

    /// An async stream of backup state changes.
    public let backupStateUpdates: AsyncStream<BackupState>
    private let backupStateUpdatesContinuation: AsyncStream<BackupState>.Continuation

    /// An async stream of recovery state changes.
    public let recoveryStateUpdates: AsyncStream<RecoveryState>
    private let recoveryStateUpdatesContinuation: AsyncStream<RecoveryState>.Continuation

    /// An async stream of verification state changes.
    public let verificationStateUpdates: AsyncStream<VerificationState>
    private let verificationStateUpdatesContinuation: AsyncStream<VerificationState>.Continuation

    /// Creates an encryption proxy.
    ///
    /// - Parameter encryption: The SDK encryption instance.
    public init(encryption: Encryption) {
        self.encryption = encryption
        self.backupState = encryption.backupState()
        self.recoveryState = encryption.recoveryState()
        self.verificationState = encryption.verificationState()

        let (backupStream, backupCont) = AsyncStream<BackupState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.backupStateUpdates = backupStream
        self.backupStateUpdatesContinuation = backupCont

        let (recoveryStream, recoveryCont) = AsyncStream<RecoveryState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.recoveryStateUpdates = recoveryStream
        self.recoveryStateUpdatesContinuation = recoveryCont

        let (verificationStream, verificationCont) = AsyncStream<VerificationState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.verificationStateUpdates = verificationStream
        self.verificationStateUpdatesContinuation = verificationCont

        backupTaskHandle = encryption.backupStateListener(listener: SDKListener { [weak self] state in
            Task { @MainActor in self?.backupState = state }
            backupCont.yield(state)
        })

        recoveryTaskHandle = encryption.recoveryStateListener(listener: SDKListener { [weak self] state in
            Task { @MainActor in self?.recoveryState = state }
            recoveryCont.yield(state)
        })

        verificationTaskHandle = encryption.verificationStateListener(listener: SDKListener { [weak self] state in
            Task { @MainActor in self?.verificationState = state }
            verificationCont.yield(state)
        })
    }

    deinit {
        backupTaskHandle?.cancel()
        recoveryTaskHandle?.cancel()
        verificationTaskHandle?.cancel()
        backupStateUpdatesContinuation.finish()
        recoveryStateUpdatesContinuation.finish()
        verificationStateUpdatesContinuation.finish()
    }

    // MARK: - Backup

    public func enableBackups() async throws {
        try await encryption.enableBackups()
    }

    public func backupExistsOnServer() async throws -> Bool {
        try await encryption.backupExistsOnServer()
    }

    public func isLastDevice() async throws -> Bool {
        try await encryption.isLastDevice()
    }

    public func waitForBackupUploadSteadyState(progressListener: BackupSteadyStateListener?) async throws {
        try await encryption.waitForBackupUploadSteadyState(progressListener: progressListener)
    }

    // MARK: - Recovery

    public func enableRecovery(waitForBackupsToUpload: Bool, passphrase: String?, progressListener: EnableRecoveryProgressListener) async throws -> String {
        try await encryption.enableRecovery(waitForBackupsToUpload: waitForBackupsToUpload, passphrase: passphrase, progressListener: progressListener)
    }

    public func disableRecovery() async throws {
        try await encryption.disableRecovery()
    }

    public func resetRecoveryKey() async throws -> String {
        try await encryption.resetRecoveryKey()
    }

    public func recover(recoveryKey: String) async throws {
        try await encryption.recover(recoveryKey: recoveryKey)
    }

    // MARK: - Identity

    public func resetIdentity() async throws -> IdentityResetHandle? {
        try await encryption.resetIdentity()
    }

    public func userIdentity(userId: String, fallbackToServer: Bool) async throws -> UserIdentity? {
        try await encryption.userIdentity(userId: userId, fallbackToServer: fallbackToServer)
    }

    // MARK: - Device Keys

    public func ed25519Key() async -> String? {
        await encryption.ed25519Key()
    }

    public func curve25519Key() async -> String? {
        await encryption.curve25519Key()
    }
}
