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
import OSLog

private let logger = Logger(subsystem: "RelayKit", category: "SessionVerification")

/// Concrete implementation of ``SessionVerificationViewModelProtocol`` backed by
/// a ``SessionVerificationControllerProxyProtocol``.
///
/// This class observes the proxy's ``SessionVerificationFlowState`` and maps it
/// to the UI-oriented ``VerificationState`` that SwiftUI views bind to. It also
/// reacts to certain proxy states by performing follow-up SDK actions:
///
/// - **Outgoing (Relay initiates):** ``requestVerification()`` sends a request.
///   When the proxy transitions to `.accepted`, this class starts SAS negotiation
///   automatically.
/// - **Incoming (Relay approves):** When the proxy transitions to
///   `.receivedRequest`, this class acknowledges and accepts the request
///   automatically if the flow hasn't progressed past the waiting stage.
///   Once the SDK confirms acceptance via `.accepted`, this class starts
///   SAS negotiation explicitly — the same as the outgoing path.
@Observable
public final class SessionVerificationViewModel: SessionVerificationViewModelProtocol {
    /// The current phase of the verification flow.
    public private(set) var state: RelayInterface.VerificationState = .idle

    /// The SAS emoji to display for comparison during the `.showingEmojis` state.
    public private(set) var emojis: [RelayInterface.VerificationEmoji] = []

    @ObservationIgnored private let controller: any SessionVerificationControllerProxyProtocol
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    private let errorReporter: ErrorReporter

    /// - Parameter controller: A proxy wrapping the SDK's verification controller.
    ///   The proxy must outlive any individual verification flow so that state
    ///   updates continue to arrive.
    public init(controller: any SessionVerificationControllerProxyProtocol, errorReporter: ErrorReporter) {
        self.controller = controller
        self.errorReporter = errorReporter
        observationTask = Task { [weak self] in
            await self?.observeFlowState()
        }
    }

    deinit {
        observationTask?.cancel()
    }

    // MARK: - Actions

    /// Sends a verification request to another device and transitions to the waiting state.
    ///
    /// If an incoming verification request from another device is already pending
    /// on the controller, this method accepts that request instead of sending a
    /// new outgoing one. This avoids a race where both sides send competing
    /// `m.key.verification.request` messages simultaneously, which the SDK cannot
    /// reconcile and causes immediate failure.
    public func requestVerification() async {
        // If an incoming request is already pending, accept it instead of
        // sending a competing outgoing request.
        if case .receivedRequest(let details) = controller.flowState {
            logger.info(
                "Incoming request already pending from \(details.deviceId), accepting instead of sending new request"
            )
            await handleIncomingRequest(details)
            return
        }

        state = .requesting
        do {
            try await controller.requestDeviceVerification()
            logger.info("Verification request sent, waiting for other device")
            state = .waitingForOtherDevice
        } catch {
            logger.error("Failed to request verification: \(error)")
            state = .failed(error.localizedDescription)
            errorReporter.report(.verificationFailed(error.localizedDescription))
        }
    }

    /// Confirms that the displayed emoji match on both devices, completing verification.
    public func approveVerification() async {
        state = .waitingForApproval
        do {
            try await controller.approveVerification()
        } catch {
            logger.error("Failed to approve verification: \(error)")
            state = .failed(error.localizedDescription)
            errorReporter.report(.verificationFailed(error.localizedDescription))
        }
    }

    /// Declines the verification because the emoji do not match.
    public func declineVerification() async {
        do {
            try await controller.declineVerification()
            state = .cancelled
        } catch {
            logger.error("Failed to decline verification: \(error)")
            state = .failed(error.localizedDescription)
            errorReporter.report(.verificationFailed(error.localizedDescription))
        }
    }

    /// Cancels the verification flow entirely.
    public func cancelVerification() async {
        do {
            try await controller.cancelVerification()
            state = .cancelled
        } catch {
            logger.error("Failed to cancel verification: \(error)")
            state = .failed(error.localizedDescription)
            errorReporter.report(.verificationFailed(error.localizedDescription))
        }
    }

    // MARK: - Proxy Observation

    /// Continuously observes the proxy's ``SessionVerificationFlowState`` and maps
    /// transitions to ``VerificationState`` updates. Certain transitions trigger
    /// follow-up actions (auto-accepting incoming requests, starting SAS for outgoing).
    private func observeFlowState() async {
        var lastProcessedState: SessionVerificationFlowState?

        while !Task.isCancelled {
            let currentState = controller.flowState

            // Process the current state if it differs from the last one we handled.
            // This catches states that changed during an earlier async handler
            // (e.g. `.accepted` arriving while `handleIncomingRequest` was awaiting)
            // without requiring a new observation cycle.
            if !currentState.isEqual(to: lastProcessedState) {
                lastProcessedState = currentState
                await handleFlowState(currentState)
                // After handling, loop back to re-check — the handler may have
                // triggered further state changes via async SDK calls.
                continue
            }

            // Wait for the next state change.
            let flowState = await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = controller.flowState
                } onChange: {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        continuation.resume(returning: controller.flowState)
                    }
                }
            }

            lastProcessedState = flowState
            await handleFlowState(flowState)
        }
    }

    /// Maps a proxy flow state to UI state, performing any required follow-up actions.
    @MainActor
    // swiftlint:disable:next cyclomatic_complexity
    private func handleFlowState(_ flowState: SessionVerificationFlowState) async {
        switch flowState {
        case .idle:
            break

        case .requested:
            // Our own request — already handled in requestVerification()
            break

        case .receivedRequest(let details):
            await handleIncomingRequest(details)

        case .accepted:
            await handleAccepted()

        case .sasStarted:
            state = .sasStarted

        case .receivedData(let data):
            handleVerificationData(data)

        case .finished:
            state = .verified

        case .cancelled:
            guard !state.isTerminal else { return }
            state = .cancelled

        case .failed:
            guard !state.isTerminal else { return }
            state = .failed("Verification failed.")
            errorReporter.report(.verificationFailed("Verification failed."))
        }
    }

    // MARK: - Flow State Handlers

    /// Handles an incoming verification request from another device.
    ///
    /// Accepts the request automatically when the current state is idle
    /// (no outgoing flow in progress). After acceptance, the SDK fires
    /// `didAcceptVerificationRequest`, which transitions to `.accepted`
    /// and triggers ``handleAccepted()`` to start SAS negotiation.
    @MainActor
    private func handleIncomingRequest(_ details: SessionVerificationRequestDetails) async {
        logger.info("Incoming verification request from \(details.deviceId)")

        guard case .idle = state else { return }

        state = .waitingForOtherDevice
        do {
            try await controller.acknowledgeVerificationRequest(
                senderId: details.senderProfile.userId,
                flowId: details.flowId
            )
            try await controller.acceptVerificationRequest()
            logger.info("Accepted incoming verification request")
        } catch {
            logger.error("Failed to accept incoming request: \(error)")
            state = .failed(error.localizedDescription)
            errorReporter.report(.verificationFailed(error.localizedDescription))
        }
    }

    /// Called when the verification request has been accepted (by either side).
    /// Explicitly starts SAS negotiation — required for both outgoing and incoming paths.
    @MainActor
    private func handleAccepted() async {
        do {
            try await controller.startSasVerification()
        } catch {
            logger.error("Failed to start SAS verification: \(error)")
            state = .failed(error.localizedDescription)
            errorReporter.report(.verificationFailed(error.localizedDescription))
        }
    }

    /// Maps SDK verification data to UI emoji or reports unsupported formats.
    @MainActor
    private func handleVerificationData(_ data: SessionVerificationData) {
        switch data {
        case .emojis(let sdkEmojis, _):
            emojis = sdkEmojis.enumerated().map { index, emoji in
                RelayInterface.VerificationEmoji(
                    id: index,
                    symbol: emoji.symbol(),
                    label: emoji.description()
                )
            }
            state = .showingEmojis
        case .decimals:
            state = .failed("Decimal verification is not supported.")
            errorReporter.report(.verificationFailed("Decimal verification is not supported."))
        }
    }
}
