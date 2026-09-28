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

import Testing

@testable import Relay

// MARK: - SessionVerificationIncomingTests

/// Incoming requests wait for the user: creating the sheet model sends
/// nothing, Accept starts the handshake, Decline ends it.
@MainActor
struct SessionVerificationIncomingTests {
    private func request() -> RelayClient.IncomingVerification {
        RelayClient.IncomingVerification(
            flowId: "flow", deviceId: "PEER", senderId: "@peer:example.com")
    }

    @Test func incomingModelWaitsForUserDecision() async {
        let client = RelayClient()
        let model = SessionVerificationViewModel(
            client: client, incoming: request())
        // The old init accepted immediately (a bare client fails the
        // accept, landing in .failed); the prompt must hold instead.
        try? await Task.sleep(for: .milliseconds(50))
        guard case .incomingRequest = model.state else {
            Issue.record("Expected .incomingRequest, got \(model.state)")
            return
        }
    }

    @Test func declineIncomingRequestCancels() async {
        let client = RelayClient()
        client.pendingVerificationRequest = request()
        let model = SessionVerificationViewModel(
            client: client, incoming: request())
        await model.declineIncomingRequest()
        guard case .cancelled = model.state else {
            Issue.record("Expected .cancelled, got \(model.state)")
            return
        }
        #expect(client.pendingVerificationRequest == nil)
    }
}
