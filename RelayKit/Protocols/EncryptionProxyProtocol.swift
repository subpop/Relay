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

// EncryptionProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

/// Manages end-to-end encryption state, key backup, and recovery.
///
/// Provides observable properties for backup, recovery, and verification
/// states, along with methods for enabling/disabling backups, managing
/// recovery keys, and accessing user identities.
///
/// ## Key Backup
///
/// The ``backupState`` property tracks the current backup state machine
/// (unknown, creating, enabling, resuming, enabled, downloading, disabling).
/// Use ``enableBackups()`` and ``waitForBackupUploadSteadyState(progressListener:)``
/// to manage backups.
///
/// ## Recovery
///
/// Recovery keys allow restoring encrypted message history on new devices.
/// Use ``enableRecovery(waitForBackupsToUpload:passphrase:progressListener:)``
/// to generate a recovery key and ``recover(recoveryKey:)`` to restore from one.
///
/// ## Topics
///
/// ### State
/// - ``backupState``
/// - ``recoveryState``
/// - ``verificationState``
///
/// ### Async Streams
/// - ``backupStateUpdates``
/// - ``recoveryStateUpdates``
/// - ``verificationStateUpdates``
///
/// ### Backup
/// - ``enableBackups()``
/// - ``backupExistsOnServer()``
///
/// ### Recovery
/// - ``enableRecovery(waitForBackupsToUpload:passphrase:progressListener:)``
/// - ``recover(recoveryKey:)``
/// - ``resetRecoveryKey()``
/// - ``disableRecovery()``
///
/// ### Identity
/// - ``userIdentity(userId:fallbackToServer:)``
/// - ``resetIdentity()``
public protocol EncryptionProxyProtocol: AnyObject, Sendable {
    // MARK: - Observable Properties

    /// The current key backup state.
    var backupState: BackupState { get }

    /// The current recovery state.
    var recoveryState: RecoveryState { get }

    /// The current session verification state.
    var verificationState: VerificationState { get }

    // MARK: - Async Streams

    /// An async stream of backup state changes.
    var backupStateUpdates: AsyncStream<BackupState> { get }

    /// An async stream of recovery state changes.
    var recoveryStateUpdates: AsyncStream<RecoveryState> { get }

    /// An async stream of verification state changes.
    var verificationStateUpdates: AsyncStream<VerificationState> { get }

    // MARK: - Backup

    /// Enables server-side key backup.
    ///
    /// - Throws: If enabling fails.
    func enableBackups() async throws

    /// Checks if a backup exists on the server.
    ///
    /// - Returns: `true` if a backup exists.
    /// - Throws: If the check fails.
    func backupExistsOnServer() async throws -> Bool

    /// Checks if this is the last verified device for the account.
    ///
    /// - Returns: `true` if this is the last device.
    /// - Throws: If the check fails.
    func isLastDevice() async throws -> Bool

    /// Waits for backup uploads to reach a steady state.
    ///
    /// - Parameter progressListener: An optional listener for upload progress.
    /// - Throws: ``SteadyStateError`` if backup is disabled or connection fails.
    func waitForBackupUploadSteadyState(progressListener: BackupSteadyStateListener?) async throws

    // MARK: - Recovery

    /// Enables recovery and returns the generated recovery key.
    ///
    /// - Parameters:
    ///   - waitForBackupsToUpload: Whether to wait for backups to finish uploading.
    ///   - passphrase: An optional passphrase for the recovery key.
    ///   - progressListener: A listener for progress updates.
    /// - Returns: The generated recovery key string.
    /// - Throws: ``RecoveryError`` if enabling fails.
    func enableRecovery(
        waitForBackupsToUpload: Bool,
        passphrase: String?,
        progressListener: EnableRecoveryProgressListener
    ) async throws -> String

    /// Disables recovery.
    ///
    /// - Throws: If disabling fails.
    func disableRecovery() async throws

    /// Resets the recovery key and returns the new one.
    ///
    /// - Returns: The new recovery key string.
    /// - Throws: If the reset fails.
    func resetRecoveryKey() async throws -> String

    /// Restores encrypted message history using a recovery key.
    ///
    /// - Parameter recoveryKey: The recovery key.
    /// - Throws: ``RecoveryError`` if recovery fails.
    func recover(recoveryKey: String) async throws

    // MARK: - Identity

    /// Resets the cross-signing identity.
    ///
    /// - Returns: A handle for completing the reset, or `nil` if not needed.
    /// - Throws: If the reset fails.
    func resetIdentity() async throws -> IdentityResetHandle?

    /// Returns the E2EE identity for a user.
    ///
    /// - Parameters:
    ///   - userId: The Matrix user ID.
    ///   - fallbackToServer: Whether to query the server if not cached.
    /// - Returns: The user identity, or `nil` if not found.
    /// - Throws: If the lookup fails.
    func userIdentity(userId: String, fallbackToServer: Bool) async throws -> UserIdentity?

    // MARK: - Device Keys

    /// Returns the device's Ed25519 key.
    ///
    /// - Returns: The key string, or `nil`.
    func ed25519Key() async -> String?

    /// Returns the device's Curve25519 key.
    ///
    /// - Returns: The key string, or `nil`.
    func curve25519Key() async -> String?
}
