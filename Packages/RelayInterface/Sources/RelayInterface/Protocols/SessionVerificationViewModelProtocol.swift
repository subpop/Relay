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

// MARK: - Models

/// A single emoji displayed during SAS (Short Authentication String) verification.
/// The Matrix protocol selects seven emoji from a fixed set; both devices must show
/// the same emoji in the same order for the user to confirm a match.
public struct VerificationEmoji: Identifiable, Sendable {
    public let id: Int
    public let symbol: String
    public let label: String

    nonisolated public init(id: Int, symbol: String, label: String) {
        self.id = id
        self.symbol = symbol
        self.label = label
    }
}

/// Tracks progress through the interactive session-verification flow.
///
/// The typical happy-path progression is:
/// `idle` -> `requesting` -> `waitingForOtherDevice` -> `sasStarted` -> `showingEmojis` -> `verified`
///
/// When Relay is the *approver* (another device initiated), the flow skips `requesting`
/// and moves directly from `idle` to `waitingForOtherDevice` once the incoming request
/// is acknowledged.
public enum VerificationState: Sendable {
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
    /// The user confirmed the emoji match; waiting for the other device to confirm.
    case waitingForApproval
    /// The user confirmed the emoji match and verification succeeded.
    case verified
    /// Either side cancelled the verification.
    case cancelled
    /// An error occurred. The associated value contains a user-facing message.
    case failed(String)

    /// Whether the state represents a final outcome that cannot transition further.
    nonisolated public var isTerminal: Bool {
        switch self {
        case .verified, .cancelled, .failed: true
        default: false
        }
    }
}

// MARK: - Protocol

/// Drives the UI for interactive session verification using SAS emoji matching.
///
/// Implementations observe the Matrix SDK's verification controller and translate
/// delegate callbacks into ``VerificationState`` and ``VerificationEmoji`` updates
/// that SwiftUI views can bind to. The flow supports both directions:
///
/// - **Relay initiates:** The view calls ``requestVerification()``, then the other
///   device accepts, SAS begins, and emoji appear.
/// - **Relay approves:** Another device initiates; the implementation auto-accepts
///   the incoming request when it arrives, and SAS begins.
@MainActor
public protocol SessionVerificationViewModelProtocol: AnyObject, Observable {
    /// The current stage of the verification flow.
    var state: VerificationState { get }
    /// The SAS emoji to display. Non-empty only when ``state`` is ``VerificationState/showingEmojis``.
    var emojis: [VerificationEmoji] { get }
    /// Sends an outgoing verification request to other sessions.
    func requestVerification() async
    /// Confirms that the displayed emoji match the other device.
    func approveVerification() async
    /// Rejects the emoji match, aborting verification.
    func declineVerification() async
    /// Cancels the verification flow at any point.
    func cancelVerification() async
}
