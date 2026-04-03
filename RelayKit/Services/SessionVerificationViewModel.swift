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

/// Concrete implementation of ``SessionVerificationViewModelProtocol`` backed by the
/// Matrix Rust SDK's `SessionVerificationController`.
///
/// This class bridges the SDK's delegate-based verification events into observable
/// state that SwiftUI views can bind to. It supports two verification directions:
///
/// - **Outgoing (Relay initiates):** ``requestVerification()`` sends a request.
///   When the other device accepts, the SDK fires `didAcceptVerificationRequest`,
///   and this class starts SAS negotiation automatically.
/// - **Incoming (Relay approves):** When another device initiates, the SDK fires
///   `didReceiveVerificationRequest`. This class acknowledges and accepts the
///   request automatically if the flow hasn't progressed past the waiting stage.
///   The SDK then starts SAS on its own — no explicit `startSasVerification()` call
///   is needed for the incoming path.
///
/// A private ``Delegate`` class receives SDK callbacks on an arbitrary thread and
/// dispatches state updates back to the `@MainActor`.
@Observable
public final class SessionVerificationViewModel: SessionVerificationViewModelProtocol {
    /// The current phase of the verification flow.
    public fileprivate(set) var state: RelayInterface.VerificationState = .idle

    /// The SAS emoji to display for comparison during the `.showingEmojis` state.
    public fileprivate(set) var emojis: [RelayInterface.VerificationEmoji] = []

    /// A user-facing error message from the most recent failed operation, if any.
    public var errorMessage: String?

    fileprivate let controller: SessionVerificationController
    private let delegate: Delegate

    /// - Parameter controller: A long-lived `SessionVerificationController` obtained
    ///   from the Matrix client during sync startup. The controller must outlive any
    ///   individual verification flow so that delegate callbacks continue to arrive.
    public init(controller: SessionVerificationController) {
        self.controller = controller
        self.delegate = Delegate()
        delegate.viewModel = self
        controller.setDelegate(delegate: delegate)
    }

    // MARK: - Actions

    /// Sends a verification request to another device and transitions to the waiting state.
    @MainActor
    public func requestVerification() async {
        state = .requesting
        do {
            try await controller.requestDeviceVerification()
            logger.info("Verification request sent, waiting for other device")
            state = .waitingForOtherDevice
        } catch {
            logger.error("Failed to request verification: \(error)")
            state = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Confirms that the displayed emoji match on both devices, completing verification.
    @MainActor
    public func approveVerification() async {
        do {
            try await controller.approveVerification()
            logger.info("Verification approved")
        } catch {
            logger.error("Failed to approve verification: \(error)")
            state = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Declines the verification because the emoji do not match.
    @MainActor
    public func declineVerification() async {
        do {
            try await controller.declineVerification()
            state = .cancelled
        } catch {
            logger.error("Failed to decline verification: \(error)")
            state = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Cancels the verification flow entirely.
    @MainActor
    public func cancelVerification() async {
        do {
            try await controller.cancelVerification()
            state = .cancelled
        } catch {
            logger.error("Failed to cancel verification: \(error)")
            state = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Delegate handlers

    /// Handles an incoming verification request from another device.
    ///
    /// Accepts the request automatically when the current state is early enough in
    /// the flow (idle, requesting, or waiting). The SDK starts SAS negotiation
    /// itself after acceptance — calling `startSasVerification()` here would
    /// conflict and cause the SDK to cancel the flow.
    @MainActor
    fileprivate func handleIncomingRequest(_ details: SessionVerificationRequestDetails) async {
        logger.info("Incoming verification request from \(details.deviceId)")
        switch state {
        case .idle, .requesting, .waitingForOtherDevice:
            break
        default:
            return
        }
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
            errorMessage = error.localizedDescription
        }
    }

    /// Called when the other device accepts our outgoing request.
    /// Explicitly starts SAS negotiation — required only for the outgoing path.
    @MainActor
    fileprivate func handleAccepted() async {
        do {
            try await controller.startSasVerification()
        } catch {
            logger.error("Failed to start SAS verification: \(error)")
            state = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - SDK Delegate

/// Bridges `SessionVerificationControllerDelegate` callbacks from the SDK (which
/// arrive on arbitrary threads) to `@MainActor` state updates on the view model.
/// Marked `nonisolated` to avoid implicit `@MainActor` isolation from the project's
/// default-isolation setting, which would prevent the SDK from calling the methods
/// from background threads.
nonisolated private final class Delegate: SessionVerificationControllerDelegate, @unchecked Sendable {
    weak var viewModel: SessionVerificationViewModel?

    func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
        Task { @MainActor [weak viewModel] in
            await viewModel?.handleIncomingRequest(details)
        }
    }

    func didAcceptVerificationRequest() {
        Task { @MainActor [weak viewModel] in
            await viewModel?.handleAccepted()
        }
    }

    func didStartSasVerification() {
        Task { @MainActor [weak viewModel] in
            viewModel?.state = .sasStarted
        }
    }

    func didReceiveVerificationData(data: SessionVerificationData) {
        Task { @MainActor [weak viewModel] in
            guard let viewModel else { return }
            switch data {
            case .emojis(let sdkEmojis, _):
                viewModel.emojis = sdkEmojis.enumerated().map { index, emoji in
                    RelayInterface.VerificationEmoji(id: index, symbol: emoji.symbol(), label: emoji.description())
                }
                viewModel.state = .showingEmojis
            case .decimals:
                viewModel.state = .failed("Decimal verification is not supported.")
                viewModel.errorMessage = "Decimal verification is not supported."
            }
        }
    }

    func didFinish() {
        Task { @MainActor [weak viewModel] in
            viewModel?.state = .verified
        }
    }

    func didCancel() {
        Task { @MainActor [weak viewModel] in
            guard let viewModel, !viewModel.state.isTerminal else { return }
            viewModel.state = .cancelled
        }
    }

    func didFail() {
        Task { @MainActor [weak viewModel] in
            guard let viewModel, !viewModel.state.isTerminal else { return }
            viewModel.state = .failed("Verification failed.")
            viewModel.errorMessage = "Verification failed."
        }
    }
}
