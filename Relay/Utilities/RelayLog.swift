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

import OSLog

// Unified-logging subsystem shared by Relay app and RelayShared.
//
// Filter all Relay logs with `subsystem == "app.subpop.Relay"`, then
// narrow by category when investigating a particular part of the app.
//
// Keep messages concise and structured: a short summary followed by
// `key=value` pairs. Use trace sparingly for high-volume detail, debug for
// routine diagnostics, info for meaningful transitions, warning for
// recoverable unexpected conditions, and error for failed operations. Log
// counts, statuses, and durations as public; keep user content, credentials,
// URLs, and identifiers private (hash identifiers when correlation is useful).
enum RelayLog {
    /// App lifecycle and app-level actions.
    nonisolated static let app = Logger(
        subsystem: "app.subpop.Relay", category: "App")
    /// Authentication, session persistence, and verification orchestration.
    nonisolated static let session = Logger(
        subsystem: "app.subpop.Relay", category: "Session")
    /// Sync lifecycle, connectivity, and retries.
    nonisolated static let sync = Logger(
        subsystem: "app.subpop.Relay", category: "Sync")
    /// Normalized local-store and cache operations.
    nonisolated static let store = Logger(
        subsystem: "app.subpop.Relay", category: "Store")
    /// Sending, composing, and message-related system integrations.
    nonisolated static let messaging = Logger(
        subsystem: "app.subpop.Relay", category: "Messaging")
    /// Timeline loading, pagination, and read state.
    nonisolated static let timeline = Logger(
        subsystem: "app.subpop.Relay", category: "Timeline")
    /// MatrixRTC and call UI orchestration.
    nonisolated static let calls = Logger(
        subsystem: "app.subpop.Relay", category: "Calls")
    /// Media fetch, processing, and paste operations.
    nonisolated static let media = Logger(
        subsystem: "app.subpop.Relay", category: "Media")
    /// App-group sharing and handoff operations.
    nonisolated static let sharing = Logger(
        subsystem: "app.subpop.Relay", category: "Sharing")
    /// Unmodified third-party LiveKit SDK output.
    nonisolated static let liveKitSDK = Logger(
        subsystem: "app.subpop.Relay", category: "LiveKitSDK")
}
