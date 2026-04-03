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

// SessionVerificationControllerProxy.swift
// RelayKit
//
// SPDX-License-Identifier: Apache-2.0

import Observation

/// An `@Observable` proxy that wraps the Matrix SDK `SessionVerificationController`.
///
/// Manages the interactive verification flow state machine. The ``flowState``
/// property updates automatically as the verification progresses through
/// its stages.
@Observable
public final class SessionVerificationControllerProxy: SessionVerificationControllerProxyProtocol, @unchecked Sendable {
    private let controller: SessionVerificationController

    /// The current verification flow state.
    public private(set) var flowState: SessionVerificationFlowState = .idle

    /// Creates a session verification controller proxy.
    ///
    /// - Parameter controller: The SDK verification controller instance.
    public init(controller: SessionVerificationController) {
        self.controller = controller
        controller.setDelegate(delegate: self)
    }

    // MARK: - Actions

    public func requestDeviceVerification() async throws {
        try await controller.requestDeviceVerification()
    }

    public func requestUserVerification(userId: String) async throws {
        try await controller.requestUserVerification(userId: userId)
    }

    public func acknowledgeVerificationRequest(senderId: String, flowId: String) async throws {
        try await controller.acknowledgeVerificationRequest(senderId: senderId, flowId: flowId)
    }

    public func acceptVerificationRequest() async throws {
        try await controller.acceptVerificationRequest()
    }

    public func startSasVerification() async throws {
        try await controller.startSasVerification()
    }

    public func approveVerification() async throws {
        try await controller.approveVerification()
    }

    public func declineVerification() async throws {
        try await controller.declineVerification()
    }

    public func cancelVerification() async throws {
        try await controller.cancelVerification()
    }
}

// MARK: - SessionVerificationControllerDelegate

extension SessionVerificationControllerProxy: SessionVerificationControllerDelegate {
    public nonisolated func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
        Task { @MainActor [weak self] in self?.flowState = .receivedRequest(details) }
    }

    public nonisolated func didAcceptVerificationRequest() {
        Task { @MainActor [weak self] in self?.flowState = .accepted }
    }

    public nonisolated func didStartSasVerification() {
        // State will be updated when data arrives via didReceiveVerificationData
    }

    public nonisolated func didReceiveVerificationData(data: SessionVerificationData) {
        Task { @MainActor [weak self] in self?.flowState = .started(data) }
    }

    public nonisolated func didFail() {
        Task { @MainActor [weak self] in self?.flowState = .failed }
    }

    public nonisolated func didCancel() {
        Task { @MainActor [weak self] in self?.flowState = .cancelled }
    }

    public nonisolated func didFinish() {
        Task { @MainActor [weak self] in self?.flowState = .finished }
    }
}
