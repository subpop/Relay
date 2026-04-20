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

import AppKit
import Foundation

// MARK: - Notification Name

extension Notification.Name {
    /// Posted when the user selects a member from the mention suggestion list.
    /// The `userInfo` dictionary contains `"userId"` and `"displayName"` strings.
    static let insertMention = Notification.Name("relay.insertMention")
}

// MARK: - Mention Helpers

extension ComposeView {
    /// Converts resolved mentions into Matrix-format markdown for the message body.
    ///
    /// Each mention's display name is replaced with a Matrix.to permalink:
    /// `[@DisplayName](https://matrix.to/#/@user:server)` which the SDK's
    /// `messageEventContentFromMarkdown` will render into proper HTML links.
    static func markdownWithMentions(text: String, mentions: [Mention]) -> String {
        guard !mentions.isEmpty else { return text }

        // Sort mentions by range location descending so we can replace from the end
        // without invalidating earlier ranges.
        let sorted = mentions.sorted { $0.range.location > $1.range.location }
        var result = text as NSString

        for mention in sorted {
            let pillText = "@\(mention.displayName)"
            let markdownLink = "[\(pillText)](https://matrix.to/#/\(mention.userId))"
            if mention.range.location + mention.range.length <= result.length {
                result = result.replacingCharacters(in: mention.range, with: markdownLink) as NSString
            }
        }

        return result as String
    }
}

/// A file staged for sending, shown as a capsule in the compose bar.
///
/// Each ``StagedAttachment`` holds the local file URL (already copied to a temp directory),
/// a display-friendly filename, an optional thumbnail for images/videos, and an optional
/// user-provided caption (alt-text).
struct StagedAttachment: Identifiable {
    let id = UUID()

    /// Local file URL (temp-directory copy, security-scoped access already resolved).
    let url: URL

    /// The original filename for display.
    let filename: String

    /// A small thumbnail image for image/video attachments, or `nil` for other file types.
    let thumbnail: NSImage?

    /// User-provided alt-text / caption. Empty string means no caption.
    var caption: String = ""
}
