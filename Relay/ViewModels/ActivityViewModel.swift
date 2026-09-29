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

/// View model for the Activity window.
///
/// Fetches slow-changing state (other-session trust counts, server
/// capabilities) on window open and every minute after, and bumps
/// `tick` on a fast poll so relative timestamps stay fresh. Everything
/// else the view reads straight off ``RelayClient``.
@Observable
final class ActivityViewModel {
    private let client: RelayClient

    /// Bumped every poll; read by the view so relative timestamps re-render.
    var tick = Date()
    /// Verified/unverified counts for this account's other sessions.
    /// Nil until the first fetch completes.
    var deviceCounts: (verified: Int, unverified: Int)?
    /// Account capabilities advertised by the server.
    /// Nil until the first fetch completes.
    var capabilities: ServerCapabilities?

    init(client: RelayClient) {
        self.client = client
    }

    /// Poll until cancelled. Started from the view's `.task`.
    func runPollLoop() async {
        var polls = 0
        while !Task.isCancelled {
            tick = Date()
            if polls % 12 == 0 {
                await refreshSlowState()
            }
            polls += 1
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
        }
    }

    /// Fetch slow-changing state (trust counts, capabilities).
    private func refreshSlowState() async {
        async let counts = client.otherDeviceVerificationCounts()
        async let capabilities = client.serverCapabilities()
        deviceCounts = await counts
        self.capabilities = await capabilities
    }
}
