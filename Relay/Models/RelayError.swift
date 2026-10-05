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
enum RelayError: LocalizedError, Sendable {

    // MARK: Authentication

    /// The operation requires an authenticated session but the user is not logged in.
    case notLoggedIn

    /// Authentication failed with the given underlying reason.
    case loginFailed(String)

    /// The session's authentication tokens expired and could not be refreshed.
    ///
    /// This typically happens with OAuth/OIDC sessions when the refresh token
    /// expires during an extended system sleep. The user must sign in again.
    case sessionExpired

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

    /// Searching the public room directory failed.
    case directorySearchFailed(String)

    /// Searching messages failed.
    case messageSearchFailed(String)

    /// Loading a space hierarchy failed.
    case spaceHierarchyFailed(String)

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

    /// A room could not be favorited or unfavorited.
    case favouriteFailed(String)

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

    /// A background key-backup restore failed.
    case keyBackupRestoreFailed(String)

    // MARK: Settings & Profile

    /// Notification settings could not be loaded or updated.
    case notificationSettingsFailed(String)

    /// Session/device information could not be loaded.
    case sessionsFailed(String)

    /// The display name could not be updated.
    case displayNameUpdateFailed(String)

    /// The user's avatar could not be updated.
    case avatarUpdateFailed(String)

    /// A direct message room could not be opened or created.
    case dmCreationFailed(String)

    // MARK: Calls

    /// A call could not be started.
    case callFailed(String)

    /// A message search request failed.
    case searchFailed(String)

    // MARK: LocalizedError

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            String(localized: "Not Signed In", comment: "Error alert title: user attempted an action that requires authentication")
        case .loginFailed:
            String(localized: "Sign In Failed", comment: "Error alert title: authentication failed")
        case .sessionExpired:
            String(localized: "Session Expired", comment: "Error alert title: the user's session tokens could not be refreshed")
        case .oauthNotSupported:
            String(localized: "OAuth Not Supported", comment: "Error alert title: the homeserver does not support OAuth login")
        case .oauthInvalidURL:
            String(localized: "Invalid OAuth URL", comment: "Error alert title: the OAuth login flow returned a malformed URL")
        case .syncFailed:
            String(localized: "Sync Error", comment: "Error alert title: the background sync service stopped with an error")
        case .roomCreationFailed:
            String(localized: "Room Creation Failed", comment: "Error alert title: creating a new room failed")
        case .roomJoinFailed:
            String(localized: "Could Not Join Room", comment: "Error alert title: joining a room failed")
        case .directorySearchFailed:
            String(localized: "Directory Search Failed", comment: "Error alert title: searching the public room directory failed")
        case .messageSearchFailed:
            String(localized: "Message Search Failed", comment: "Error alert title: searching messages failed")
        case .spaceHierarchyFailed:
            String(localized: "Space Hierarchy Failed", comment: "Error alert title: loading a space's room hierarchy failed")
        case .roomLeaveFailed:
            String(localized: "Could Not Leave Room", comment: "Error alert title: leaving a room failed")
        case .roomNotFound:
            String(localized: "Room Not Found", comment: "Error alert title: the requested room does not exist or is inaccessible")
        case .messageSendFailed:
            String(localized: "Could Not Send Message", comment: "Error alert title: sending a message failed")
        case .messageLoadFailed:
            String(localized: "Could Not Load Messages", comment: "Error alert title: loading timeline messages failed")
        case .reactionFailed:
            String(localized: "Could Not Toggle Reaction", comment: "Error alert title: adding or removing an emoji reaction failed")
        case .editFailed:
            String(localized: "Could Not Edit Message", comment: "Error alert title: editing a sent message failed")
        case .redactFailed:
            String(localized: "Could Not Delete Message", comment: "Error alert title: deleting (redacting) a message failed")
        case .pinFailed:
            String(localized: "Could Not Update Pin", comment: "Error alert title: pinning or unpinning a message failed")
        case .favouriteFailed:
            String(localized: "Could Not Update Favorite", comment: "Error alert title: favoriting or unfavoriting a room failed")
        case .mediaPreviewFailed:
            String(localized: "Could Not Preview File", comment: "Error alert title: generating a preview for a media attachment failed")
        case .mediaSaveFailed:
            String(localized: "Could Not Save File", comment: "Error alert title: saving a media attachment to disk failed")
        case .attachmentSendFailed:
            String(localized: "Could Not Send Attachment", comment: "Error alert title: sending a file attachment failed")
        case .fileCopyFailed:
            String(localized: "Could Not Read File", comment: "Error alert title: copying a file for upload staging failed")
        case .verificationFailed:
            String(localized: "Verification Failed", comment: "Error alert title: device/session cross-signing verification failed")
        case .keyBackupRestoreFailed:
            String(localized: "Could Not Restore Backup", comment: "Error alert title: restoring encryption keys from backup failed")
        case .notificationSettingsFailed:
            String(localized: "Notification Settings Error", comment: "Error alert title: loading or updating notification settings failed")
        case .sessionsFailed:
            String(localized: "Sessions Error", comment: "Error alert title: loading the list of active login sessions/devices failed")
        case .displayNameUpdateFailed:
            String(localized: "Could Not Update Display Name", comment: "Error alert title: changing the user's display name failed")
        case .avatarUpdateFailed:
            String(localized: "Could Not Update Avatar", comment: "Error alert title: changing the user's profile photo failed")
        case .dmCreationFailed:
            String(localized: "Could Not Open Conversation", comment: "Error alert title: opening or creating a direct message room failed")
        case .callFailed:
            String(localized: "Call Failed", comment: "Error alert title: starting or joining a voice/video call failed")
        case .searchFailed:
            String(localized: "Search Failed", comment: "Error alert title: a message search request failed")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notLoggedIn:
            String(localized: "Please sign in to continue.", comment: "Error alert message: prompts the user to sign in")
        case .loginFailed(let reason):
            // `reason` originates from the Matrix SDK or homeserver, not Relay's own UI copy, so it isn't localized here.
            reason
        case .sessionExpired:
            String(localized: "Your session's authentication token could not be refreshed. Please sign in again.", comment: "Error alert message: OAuth/OIDC refresh token expired")
        case .oauthNotSupported:
            String(localized: "This homeserver does not support OAuth login.", comment: "Error alert message: homeserver lacks OAuth support")
        case .oauthInvalidURL:
            String(localized: "The OAuth login URL was invalid.", comment: "Error alert message: malformed OAuth login URL")
        case .syncFailed(let reason):
            reason
        case .roomCreationFailed(let reason):
            reason
        case .roomJoinFailed(let reason):
            reason
        case .directorySearchFailed(let reason):
            reason
        case .messageSearchFailed(let reason):
            reason
        case .spaceHierarchyFailed(let reason):
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
        case .favouriteFailed(let reason):
            reason
        case .mediaPreviewFailed(let filename, let reason):
            String(localized: "Could not preview \(filename): \(reason)", comment: "Error alert message: filename is the attachment's name, reason is why the preview failed")
        case .mediaSaveFailed(let filename, let reason):
            String(localized: "Could not save \(filename): \(reason)", comment: "Error alert message: filename is the attachment's name, reason is why saving failed")
        case .attachmentSendFailed(let filename, let reason):
            String(localized: "Could not send \(filename): \(reason)", comment: "Error alert message: filename is the attachment's name, reason is why sending failed")
        case .fileCopyFailed(let filename, let reason):
            String(localized: "Could not read \(filename): \(reason)", comment: "Error alert message: filename is the attachment's name, reason is why reading failed")
        case .verificationFailed(let reason):
            reason
        case .keyBackupRestoreFailed(let reason):
            reason
        case .notificationSettingsFailed(let reason):
            reason
        case .sessionsFailed(let reason):
            reason
        case .displayNameUpdateFailed(let reason):
            reason
        case .avatarUpdateFailed(let reason):
            reason
        case .dmCreationFailed(let reason):
            reason
        case .callFailed(let reason):
            reason
        case .searchFailed(let reason):
            reason
        }
    }
}
