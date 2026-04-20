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

/// Determines whether a message body should be highlighted based on the current
/// user's ID and their notification keywords.
///
/// This centralizes the client-side highlight detection logic used by both
/// ``TimelineMessageMapper`` (for the timeline "@" badge) and ``RoomListManager``
/// (for notification events and unread indicators). Using a single implementation
/// ensures consistent matching behavior across the app.
enum HighlightMatcher {
    /// Returns whether the given message body matches highlight rules.
    ///
    /// A body is considered highlighted if it contains the current user's Matrix ID
    /// or any of the notification keywords (using locale-aware, case-insensitive matching).
    ///
    /// - Parameters:
    ///   - body: The plain-text message body to check.
    ///   - currentUserId: The signed-in user's Matrix ID (e.g. `"@alice:matrix.org"`).
    ///   - keywords: The user's notification keywords.
    /// - Returns: `true` if the body matches any highlight rule.
    static func bodyMatchesHighlightRules(
        _ body: String,
        currentUserId: String?,
        keywords: [String]
    ) -> Bool {
        if let userId = currentUserId, body.contains(userId) {
            return true
        }
        if keywords.contains(where: { body.localizedStandardContains($0) }) {
            return true
        }
        return false
    }
}
