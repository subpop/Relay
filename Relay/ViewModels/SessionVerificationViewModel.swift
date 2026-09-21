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
import Observation

/// Progress through the interactive session-verification flow.
///
/// The happy path for SAS (emoji) verification is:
/// `idle` -> `requesting` -> `waitingForOtherDevice` -> `sasStarted` ->
/// `showingEmojis` -> `waitingForApproval` -> `verified`
///
/// When the account has a key backup, a verified SAS flow additionally
/// offers the restore step before finishing: `waitingForApproval` ->
/// `awaitingBackupKey` -> `awaitingBackupRestore`/`restoringBackup` ->
/// `verified`.
///
/// A fresh device holds no cross-signing keys, so after the handshake
/// approval may extend through key sharing until the peer approves and
/// the secrets arrive.
///
/// When Relay approves (another device initiated), the flow moves from
/// `idle` to `waitingForOtherDevice` once the incoming request is
/// acknowledged.
///
/// Recovery-key verification unlocks 4S secret storage and imports
/// the cross-signing keys, verifying the session without a second
/// device: `idle` -> `enteringRecovery` -> `recovering` ->
/// `awaitingBackupRestore`/`restoringBackup` -> `verified`. The restore
/// step appears only when 4S holds a backup key.
enum SessionVerificationState: Sendable {
    /// No verification in progress.
    case idle
    /// An outgoing verification request is being sent.
    case requesting
    /// Waiting for the other device to accept the request or start SAS.
    case waitingForOtherDevice
    /// SAS negotiation has started; emoji are being computed.
    case sasStarted
    /// Emoji are ready for the user to compare and confirm.
    case showingEmojis
    /// The user confirmed the emoji match; waiting for the other device
    /// to confirm, then (on a fresh device) to approve key sharing.
    case waitingForApproval
    /// Verified via SAS and asking the peer for the key-backup key;
    /// the restore prompt follows on arrival (or plain verified on
    /// skip/timeout).
    case awaitingBackupKey
    /// The user is entering a recovery key or passphrase.
    case enteringRecovery
    /// 4S secret storage is being unlocked and keys imported.
    case recovering
    /// 4S recovery produced a backup key; waiting on the user's choice
    /// to restore message history or skip.
    case awaitingBackupRestore
    /// Backed-up megolm sessions are being downloaded and imported.
    case restoringBackup
    /// Verification succeeded.
    case verified
    /// Either side cancelled the verification.
    case cancelled
    /// An error occurred. The associated value contains a user-facing message.
    case failed(String)
}

/// Drives the session verification sheet: SAS emoji matching, or 4S
/// recovery-key unlock for accounts with secret storage.
///
/// Holds a MatrixKit ``VerificationSession`` (created for an outgoing
/// request or an accepted incoming request) and maps
/// ``VerificationMonitor`` events onto UI states. The monitor advances
/// the handshake itself (start/accept/key/done); the only explicit
/// actions here are starting/accepting, `approveVerification()` after
/// the user confirms the emoji match, and cancel/decline.
@Observable
final class SessionVerificationViewModel: Identifiable {
    let id = UUID()

    /// The current UI state of the flow.
    var state: SessionVerificationState = .idle

    /// Emoji for the user to compare, once exchanged.
    var emojis: [SASEmoji] = []

    /// The backup key recovered from 4S, if any — feeds the restore step.
    private var backupPrivateKey: Data?

    /// Sessions imported by the restore step, for the success message.
    var restoredSessionCount = 0

    /// Whether another device exists to verify against.
    var hasOtherDevices = false

    private var client: RelayClient?
    private var session: VerificationSession?
    private var eventsTask: Task<Void, Never>?
    private var keyShareTask: Task<Void, Never>?

    /// Creates a model for an outgoing verification flow.
    init(client: RelayClient) {
        self.client = client
    }

    /// Creates a model that immediately acknowledges an incoming request.
    init(client: RelayClient, incoming request: RelayClient.IncomingVerification) {
        self.client = client
        Task { await acceptIncoming(request) }
    }

    // MARK: - Flow Entry Points

    /// Check for other devices, for the idle screen's button layout.
    func checkForOtherDevices() async {
        guard let client else { return }
        let devices = (try? await client.devices()) ?? []
        let ownId = await client.deviceId()
        hasOtherDevices = devices.contains { $0.deviceId.value != ownId }
    }

    /// Start verifying this session against another of the user's devices.
    func requestVerification() async {
        guard let client, let userId = client.userId() else { return }
        state = .requesting
        do {
            let session = try await client.requestVerification(
                userId: userId, deviceId: nil)
            self.session = session
            state = .waitingForOtherDevice
            startListening(session: session)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Acknowledge an incoming request and start the handshake as responder.
    func acceptIncoming(_ request: RelayClient.IncomingVerification) async {
        guard let client else { return }
        state = .waitingForOtherDevice
        do {
            let session = try await client.acceptVerificationRequest(request)
            self.session = session
            startListening(session: session)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - User Actions

    /// Confirm the emoji match and send our MAC.
    func approveVerification() async {
        guard let client, let session else { return }
        do {
            try await client.confirmVerification(session)
            state = .waitingForApproval
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Reject the emoji match.
    func declineVerification() async {
        await cancelFlow()
    }

    /// Cancel the in-progress flow.
    func cancelVerification() async {
        await cancelFlow()
    }

    /// Reset the flow back to idle (from recovery entry).
    func resetToIdle() {
        state = .idle
    }

    /// Show the recovery key / passphrase entry form.
    func startRecoveryEntry() {
        state = .enteringRecovery
    }

    /// Unlock 4S secret storage with an `Es...` recovery key and import
    /// the cross-signing keys.
    func submitRecoveryKey(_ key: String) async {
        state = .recovering
        guard let client else {
            state = .failed("Not signed in.")
            return
        }
        do {
            let outcome = try await client.recover(withRecoveryKey: key)
            await finishRecovery(client: client, outcome: outcome)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Download and import backed-up megolm sessions with the key
    /// recovered from 4S, then report the session verified. Large
    /// restores run as a single task behind a progress view.
    func restoreBackup() async {
        state = .restoringBackup
        guard let client, let backupKey = backupPrivateKey else {
            state = .failed("Not signed in.")
            return
        }
        do {
            restoredSessionCount = try await client.restoreKeyBackup(privateKey: backupKey)
            backupPrivateKey = nil
            state = .verified
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Skip the restore step and report the session verified.
    func skipBackupRestore() {
        backupPrivateKey = nil
        state = .verified
    }

    /// After a successful unlock, confirm the healed state before
    /// reporting success — importing keys alone does not prove this
    /// device carries a valid self-signature yet. When 4S holds a
    /// backup key, offer the restore step instead of finishing.
    private func finishRecovery(client: RelayClient, outcome: RecoveryOutcome) async {
        await client.refreshVerificationState()
        if client.isSessionVerified {
            if let backupKey = outcome.backupPrivateKey {
                backupPrivateKey = backupKey
                state = .awaitingBackupRestore
            } else {
                state = .verified
            }
        } else {
            state = .failed(
                "Keys recovered, but this session is still unverified.")
        }
    }

    // MARK: - Monitor Events

    /// Map the shared monitor's lifecycle events for our flow onto UI
    /// states. The monitor drives the handshake; this only observes.
    private func startListening(session: VerificationSession) {
        eventsTask?.cancel()
        eventsTask = Task { [weak self, weak client] in
            guard let client, let monitor = await client.verificationMonitor() else { return }
            let stream = await monitor.events()
            for await event in stream {
                guard let self else { return }
                let transactionId = await session.transactionId
                switch event {
                case .sasReady(let id, let emoji, _)
                    where id == transactionId:
                    emojis = emoji
                    state = .showingEmojis
                case .failed(let id, let message)
                    where id == transactionId:
                    fail(with: VerificationError(message: message))
                    return
                case .sessionFinished(let id)
                    where id == transactionId:
                    await self.finish(session: session)
                    return
                default:
                    break
                }
            }
        }
    }

    /// Record a handshake failure and stop listening. Terminal states
    /// win: a late failure must never overwrite success or cancellation.
    private func fail(with error: Error) {
        if case .verified = state { return }
        if case .cancelled = state { return }
        if case .failed = state { return }
        state = .failed(error.localizedDescription)
        stopListening()
    }

    private func finish(session: VerificationSession) async {
        switch await session.state {
        case .done, .macSent, .macReceived:
            if case .failed = state { return }
            do {
                switch try await client?.completeSelfVerification(session) {
                case .waitingForKeyShare:
                    waitForKeyShare(peerDeviceId: await session.peerDeviceId)
                case .verified, nil:
                    state = .verified
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
            await client?.refreshVerificationState()
        case .cancelled:
            if case .failed = state { return }
            state = .cancelled
        default:
            break
        }
        stopListening()
    }

    /// After requesting secrets, watch for their arrival and flip to
    /// verified once the healed state confirms it. Refreshes first in
    /// case the secrets beat the subscription. Only the approval state
    /// may advance — a terminal state always wins. Once verified, the
    /// backup-restore step is offered when the account has a key
    /// backup, mirroring the recovery-key path.
    private func waitForKeyShare(peerDeviceId: String?) {
        state = .waitingForApproval
        keyShareTask?.cancel()
        keyShareTask = Task { [weak self, weak client] in
            guard let client, let self else { return }
            await client.refreshVerificationState()
            if client.isSessionVerified, case .waitingForApproval = state {
                await self.finishVerified(client: client, peerDeviceId: peerDeviceId)
                return
            }
            guard let stream = await client.secretShareEvents() else { return }
            for await _ in stream {
                await client.refreshVerificationState()
                if client.isSessionVerified, case .waitingForApproval = self.state {
                    await self.finishVerified(client: client, peerDeviceId: peerDeviceId)
                    return
                }
            }
        }
    }

    /// Verified via SAS secrets — offer the backup-restore step when
    /// the account has a key backup, else report plain verified.
    private func finishVerified(client: RelayClient, peerDeviceId: String?) async {
        guard case .waitingForApproval = state else { return }
        if await offerBackupRestore(client: client, peerDeviceId: peerDeviceId) {
            return
        }
        // The offer either never started (plain verified) or timed out
        // waiting for the key — either way our own waiting states
        // advance; terminal states (cancelled/failed) always win.
        switch state {
        case .waitingForApproval, .awaitingBackupKey:
            state = .verified
        default:
            break
        }
    }

    /// Request the backup key from the verified peer and surface the
    /// restore prompt on arrival. Returns false (caller reports plain
    /// verified) when there is no backup, the request fails, the user
    /// cancels, or the peer does not answer within the timeout.
    private func offerBackupRestore(client: RelayClient, peerDeviceId: String?) async -> Bool {
        guard await client.encryptionStatus().backupEnabled else { return false }
        guard (try? await client.requestBackupKey(from: peerDeviceId)) != nil else {
            return false
        }
        guard let stream = await client.secretShareEvents() else { return false }
        state = .awaitingBackupKey
        let key = await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                for await event in stream {
                    if case .backupKeyReceived(let key) = event {
                        return key
                    }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(15))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard case .awaitingBackupKey = state else { return false }
        guard let key else { return false }
        backupPrivateKey = key
        state = .awaitingBackupRestore
        return true
    }

    private func stopKeyShare() {
        keyShareTask?.cancel()
        keyShareTask = nil
    }

    private func cancelFlow() async {
        if let session {
            try? await session.cancel()
        }
        state = .cancelled
        stopListening()
        stopKeyShare()
    }

    private func stopListening() {
        eventsTask?.cancel()
        eventsTask = nil
    }
}

/// A monitor-reported flow failure, surfaced as a UI error message.
private struct VerificationError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
