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

// MARK: - KeyBackupPresentation

/// What the Key Backup section of the Encryption settings shows for this
/// device's standing with the account's server-side key backup.
struct KeyBackupPresentation: Equatable {

    /// Whether the status is reassuring or needs the user's attention.
    enum Tone: Equatable {
        case good
        case warning
    }

    let icon: String
    let tone: Tone
    let title: String
    let detail: String

    /// Pending keys can be uploaded right now.
    let canBackUpNow: Bool

    /// A backup exists to restore message history from.
    let canRestore: Bool

    /// The account has no backup, so this device can create one.
    let canSetUp: Bool

    private static let activeIcon = "arrow.triangle.2.circlepath"
    private static let warningIcon = "exclamationmark.arrow.triangle.2.circlepath"

    /// - Parameters:
    ///   - status: This device's backup status, nil when it could not be
    ///     determined (logged out, offline).
    ///   - isSessionVerified: Whether this session is cross-signing
    ///     verified; it decides how an untrusted backup is explained.
    init(status: KeyBackupStatus?, isSessionVerified: Bool) {
        guard let status else {
            self.init(
                icon: Self.warningIcon, tone: .warning,
                title: String(
                    localized: "Key Backup Unavailable",
                    comment: "Settings: key backup status could not be determined"),
                detail: String(
                    localized: "Relay could not check the key backup. Check your connection and try again.",
                    comment: "Settings: explains why the key backup status is unavailable"),
                canBackUpNow: false, canRestore: false, canSetUp: false)
            return
        }
        guard status.exists else {
            self.init(
                icon: Self.warningIcon, tone: .warning,
                title: String(
                    localized: "Key Backup Not Active",
                    comment: "Settings: the account has no key backup"),
                detail: String(
                    localized: "Message keys are not being backed up. You may lose access to encrypted history.",
                    comment: "Settings: warns that encrypted history is not backed up"),
                canBackUpNow: false, canRestore: false, canSetUp: true)
            return
        }
        guard status.isTrusted else {
            self.init(
                icon: Self.warningIcon, tone: .warning,
                title: String(
                    localized: "Key Backup Not in Use",
                    comment: "Settings: a key backup exists but this device is not adding keys to it"),
                detail: isSessionVerified
                    ? String(
                        localized: "This backup is not signed by a device or key you trust, so Relay is not adding message keys to it.",
                        comment: "Settings: explains why an unsigned key backup is not used")
                    : String(
                        localized: "Verify this session to back up message keys.",
                        comment: "Settings: a key backup is not used until this session is verified"),
                canBackUpNow: false, canRestore: true, canSetUp: false)
            return
        }
        var detail = String(
            localized: "Message keys backed up: \(status.backedUpSessions.formatted()). Waiting to upload: \(status.pendingSessions.formatted()).",
            comment: "Settings: counts of message keys stored in the key backup and waiting to be uploaded")
        if status.unattributedSessions > 0 {
            detail += " " + String(
                localized: "\(status.unattributedSessions.formatted()) older keys cannot be added to the backup.",
                comment: "Settings: count of stored message keys that lack the information a backup needs")
        }
        self.init(
            icon: Self.activeIcon, tone: .good,
            title: String(
                localized: "Key Backup Active",
                comment: "Settings: this device is adding message keys to the key backup"),
            detail: detail,
            canBackUpNow: status.pendingSessions > 0, canRestore: true, canSetUp: false)
    }

    private init(
        icon: String, tone: Tone, title: String, detail: String,
        canBackUpNow: Bool, canRestore: Bool, canSetUp: Bool
    ) {
        self.icon = icon
        self.tone = tone
        self.title = title
        self.detail = detail
        self.canBackUpNow = canBackUpNow
        self.canRestore = canRestore
        self.canSetUp = canSetUp
    }
}
