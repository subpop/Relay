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

// SessionVerificationControllerProxyProtocol.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

/// The state of an interactive session verification flow.
///
/// Tracks the verification flow from idle through to completion,
/// cancellation, or failure.
public enum SessionVerificationFlowState: Sendable {
    /// No verification is in progress.
    case idle
    /// A verification request has been sent and is awaiting acceptance.
    case requested(SessionVerificationRequestDetails)
    /// A verification request has been received from another device.
    case receivedRequest(SessionVerificationRequestDetails)
    /// The verification request has been accepted by the other device.
    case accepted
    /// SAS negotiation has started; emoji data is being computed.
    case sasStarted
    /// SAS verification data (emoji or decimals) is available for comparison.
    case receivedData(SessionVerificationData)
    /// The verification was cancelled.
    case cancelled
    /// The verification failed.
    case failed
    /// The verification completed successfully.
    case finished

    /// A tag that identifies the case without comparing associated values.
    /// Used by the observation loop to detect state transitions.
    var tag: Int {
        switch self {
        case .idle: 0
        case .requested: 1
        case .receivedRequest: 2
        case .accepted: 3
        case .sasStarted: 4
        case .receivedData: 5
        case .cancelled: 6
        case .failed: 7
        case .finished: 8
        }
    }

    /// Returns `true` when this state represents the same case as `other`.
    func isEqual(to other: SessionVerificationFlowState?) -> Bool {
        guard let other else { return false }
        return tag == other.tag
    }
}

/// Controls an interactive session verification flow (SAS emoji/decimal).
///
/// The verification controller manages the state machine for verifying
/// a device or user via Short Authentication String (SAS). The flow
/// progresses through states: idle -> requested -> accepted -> started
/// (with emoji or decimal data) -> approved/declined/cancelled/failed/finished.
///
/// ```swift
/// struct VerificationView: View {
///     let controller: any SessionVerificationControllerProxyProtocol
///
///     var body: some View {
///         switch controller.flowState {
///         case .idle:
///             Button("Verify") {
///                 Task { try await controller.requestDeviceVerification() }
///             }
///         case .started(let data):
///             EmojiVerificationView(data: data)
///         case .finished:
///             Text("Verified!")
///         default:
///             ProgressView()
///         }
///     }
/// }
/// ```
///
/// ## Topics
///
/// ### State
/// - ``flowState``
///
/// ### Initiating
/// - ``requestDeviceVerification()``
/// - ``requestUserVerification(userId:)``
/// - ``acceptVerificationRequest()``
///
/// ### SAS Flow
/// - ``startSasVerification()``
/// - ``approveVerification()``
/// - ``declineVerification()``
/// - ``cancelVerification()``
public protocol SessionVerificationControllerProxyProtocol: AnyObject, Sendable { // swiftlint:disable:this type_name
    /// The current verification flow state.
    var flowState: SessionVerificationFlowState { get }

    /// Initiates a device verification request.
    ///
    /// - Throws: If the request fails.
    func requestDeviceVerification() async throws

    /// Initiates a user verification request.
    ///
    /// - Parameter userId: The Matrix user ID to verify.
    /// - Throws: If the request fails.
    func requestUserVerification(userId: String) async throws

    /// Acknowledges and processes a received verification request.
    ///
    /// - Parameters:
    ///   - senderId: The sender's user ID.
    ///   - flowId: The verification flow ID.
    /// - Throws: If acknowledgement fails.
    func acknowledgeVerificationRequest(senderId: String, flowId: String) async throws

    /// Accepts an incoming verification request.
    ///
    /// - Throws: If accepting fails.
    func acceptVerificationRequest() async throws

    /// Starts the SAS verification exchange.
    ///
    /// After calling this, the ``flowState`` will transition to
    /// ``SessionVerificationFlowState/started(_:)`` with emoji or
    /// decimal data to display.
    ///
    /// - Throws: If starting fails.
    func startSasVerification() async throws

    /// Confirms the displayed emoji/decimals match.
    ///
    /// - Throws: If approval fails.
    func approveVerification() async throws

    /// Declines the verification (emoji/decimals don't match).
    ///
    /// - Throws: If declining fails.
    func declineVerification() async throws

    /// Cancels the verification flow.
    ///
    /// - Throws: If cancellation fails.
    func cancelVerification() async throws
}
