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

/// Summary of the client's encryption, key backup, and recovery state.
public struct EncryptionStatus: Sendable {
    /// Whether server-side key backup is active, allowing message keys to be recovered on new sessions.
    public let backupEnabled: Bool

    /// Whether account recovery (via a recovery key or passphrase) has been configured.
    public let recoveryEnabled: Bool

    /// Creates a new ``EncryptionStatus`` value.
    ///
    /// - Parameters:
    ///   - backupEnabled: `true` when key backup is enabled on the server.
    ///   - recoveryEnabled: `true` when account recovery has been set up.
    nonisolated public init(backupEnabled: Bool = false, recoveryEnabled: Bool = false) {
        self.backupEnabled = backupEnabled
        self.recoveryEnabled = recoveryEnabled
    }
}
