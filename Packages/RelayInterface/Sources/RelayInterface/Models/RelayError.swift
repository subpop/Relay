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

/// A unified error type for user-facing errors throughout the Relay app.
///
/// ``RelayError`` conforms to `LocalizedError` so it can be used directly with
/// SwiftUI's `.alert(isPresented:error:actions:message:)` modifier. Each case
/// provides a clear `errorDescription` (used as the alert title) and a
/// `recoverySuggestion` (used as the alert message body).
public enum RelayError: LocalizedError, Sendable {

    // MARK: Authentication

    /// The operation requires an authenticated session but the user is not logged in.
    case notLoggedIn

    /// Authentication failed with the given underlying reason.
    case loginFailed(String)

    /// The homeserver does not support OAuth login.
    case oauthNotSupported

    /// An invalid URL was returned during the OAuth flow.
    case oauthInvalidURL

    // MARK: Sync

    /// The sync service encountered an error and stopped.
    case syncFailed(String)

    // MARK: Room Operations

    /// A room could not be created.
    case roomCreationFailed(String)

    /// Joining a room failed.
    case roomJoinFailed(String)

    /// Leaving a room failed.
    case roomLeaveFailed(String)

    /// The requested room was not found.
    case roomNotFound(String)

    // MARK: Messages & Timeline

    /// A message could not be sent.
    case messageSendFailed(String)

    /// Messages could not be loaded from the timeline.
    case messageLoadFailed(String)

    /// A reaction could not be toggled.
    case reactionFailed(String)

    /// A message could not be edited.
    case editFailed(String)

    /// A message could not be deleted (redacted).
    case redactFailed(String)

    /// A message could not be pinned or unpinned.
    case pinFailed(String)

    // MARK: Media

    /// A media file could not be previewed.
    case mediaPreviewFailed(filename: String, reason: String)

    /// A media file could not be saved to disk.
    case mediaSaveFailed(filename: String, reason: String)

    /// An attachment could not be sent.
    case attachmentSendFailed(filename: String, reason: String)

    /// A file could not be copied for staging.
    case fileCopyFailed(filename: String, reason: String)

    // MARK: Verification

    /// Session verification failed.
    case verificationFailed(String)

    // MARK: Settings & Profile

    /// Notification settings could not be loaded or updated.
    case notificationSettingsFailed(String)

    /// Session/device information could not be loaded.
    case sessionsFailed(String)

    /// The display name could not be updated.
    case displayNameUpdateFailed(String)

    /// A direct message room could not be opened or created.
    case dmCreationFailed(String)

    // MARK: Calls

    /// A call could not be started.
    case callFailed(String)

    // MARK: LocalizedError

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not Signed In"
        case .loginFailed:
            "Sign In Failed"
        case .oauthNotSupported:
            "OAuth Not Supported"
        case .oauthInvalidURL:
            "Invalid OAuth URL"
        case .syncFailed:
            "Sync Error"
        case .roomCreationFailed:
            "Room Creation Failed"
        case .roomJoinFailed:
            "Could Not Join Room"
        case .roomLeaveFailed:
            "Could Not Leave Room"
        case .roomNotFound:
            "Room Not Found"
        case .messageSendFailed:
            "Could Not Send Message"
        case .messageLoadFailed:
            "Could Not Load Messages"
        case .reactionFailed:
            "Could Not Toggle Reaction"
        case .editFailed:
            "Could Not Edit Message"
        case .redactFailed:
            "Could Not Delete Message"
        case .pinFailed:
            "Could Not Update Pin"
        case .mediaPreviewFailed:
            "Could Not Preview File"
        case .mediaSaveFailed:
            "Could Not Save File"
        case .attachmentSendFailed:
            "Could Not Send Attachment"
        case .fileCopyFailed:
            "Could Not Read File"
        case .verificationFailed:
            "Verification Failed"
        case .notificationSettingsFailed:
            "Notification Settings Error"
        case .sessionsFailed:
            "Sessions Error"
        case .displayNameUpdateFailed:
            "Could Not Update Display Name"
        case .dmCreationFailed:
            "Could Not Open Conversation"
        case .callFailed:
            "Call Failed"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notLoggedIn:
            "Please sign in to continue."
        case .loginFailed(let reason):
            reason
        case .oauthNotSupported:
            "This homeserver does not support OAuth login."
        case .oauthInvalidURL:
            "The OAuth login URL was invalid."
        case .syncFailed(let reason):
            reason
        case .roomCreationFailed(let reason):
            reason
        case .roomJoinFailed(let reason):
            reason
        case .roomLeaveFailed(let reason):
            reason
        case .roomNotFound(let reason):
            reason
        case .messageSendFailed(let reason):
            reason
        case .messageLoadFailed(let reason):
            reason
        case .reactionFailed(let reason):
            reason
        case .editFailed(let reason):
            reason
        case .redactFailed(let reason):
            reason
        case .pinFailed(let reason):
            reason
        case .mediaPreviewFailed(let filename, let reason):
            "Could not preview \(filename): \(reason)"
        case .mediaSaveFailed(let filename, let reason):
            "Could not save \(filename): \(reason)"
        case .attachmentSendFailed(let filename, let reason):
            "Could not send \(filename): \(reason)"
        case .fileCopyFailed(let filename, let reason):
            "Could not read \(filename): \(reason)"
        case .verificationFailed(let reason):
            reason
        case .notificationSettingsFailed(let reason):
            reason
        case .sessionsFailed(let reason):
            reason
        case .displayNameUpdateFailed(let reason):
            reason
        case .dmCreationFailed(let reason):
            reason
        case .callFailed(let reason):
            reason
        }
    }
}
